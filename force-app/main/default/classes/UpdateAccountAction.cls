/**
 * Agentforce custom action: updates key fields on an Account the user names,
 * or on the Account record the user is viewing.
 *
 * Design notes:
 *  - Runs in USER_MODE, so the agent can only touch what the running user's
 *    profile, permission sets and sharing rules allow.
 *  - Validates picklist values against the org's schema so the LLM cannot
 *    write values that don't exist ("Super Hot").
 *  - Never guesses on ambiguous names: returns the candidate list so the agent
 *    can ask the user which one they meant.
 *  - Logs every change to Agent_Change_Log__c (see AgentChangeLog) in the same
 *    transaction as the update: no change without a log entry. Log writes are
 *    explicitly SYSTEM_MODE (Apex defaults to user mode from API 67.0), so users
 *    can read the log but cannot write to it themselves.
 *  - Revenue changes involving more than $100M are not applied here: they are
 *    logged as Pending Approval and sent to the user's manager. The rule lives
 *    in the action rather than the agent's instructions, so no caller can skip it.
 *  - Lookups are bulkified (one query per lookup style for all requests), as
 *    invocable methods may be called with multiple requests.
 */
public with sharing class UpdateAccountAction {

    /** Revenue changes need a manager's approval when the revenue before or after the change is over this. */
    public static final Decimal APPROVAL_THRESHOLD = 100000000;

    public class Request {
        @InvocableVariable(
            label='Account Id'
            description='Salesforce Id of the Account to update (starts with 001), e.g. the record the user is viewing. Takes precedence over Account to Update.')
        public String accountId;

        @InvocableVariable(
            label='Account to Update'
            description='Name (or part of the name) of the existing Account to update, e.g. "Acme Robotics" or "Acme". Only used to find the record; the name itself is never changed.')
        public String accountName;

        @InvocableVariable(
            label='Rating'
            description='New Account rating. Allowed values: Hot, Warm, Cold. Leave empty to keep the current value.')
        public String rating;

        @InvocableVariable(
            label='Industry'
            description='New Industry, e.g. Technology, Finance, Healthcare, Retail, Energy. Leave empty to keep the current value.')
        public String industry;

        @InvocableVariable(
            label='Type'
            description='New Account type, e.g. Prospect, Customer - Direct, Customer - Channel. Leave empty to keep the current value.')
        public String accountType;

        @InvocableVariable(
            label='Annual Revenue'
            description='New annual revenue in US dollars as a plain number, e.g. 25000000 for $25M. Leave empty to keep the current value.')
        public Decimal annualRevenue;

        @InvocableVariable(
            label='Original Request'
            description='The user\'s request that led to this change, in their own words, e.g. "Make this one Hot". Saved to the change log; it is not a field to change.')
        public String originalRequest;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True if the changes were made or sent for approval.')
        public Boolean success;

        @InvocableVariable(label='Pending Approval' description='True if a change was sent to the user\'s manager for approval and is not applied yet.')
        public Boolean pendingApproval;

        @InvocableVariable(label='Message' description='Human-readable result to relay to the user, including what changed, what is waiting for approval, or why nothing changed.')
        public String message;

        @InvocableVariable(label='Account Id' description='Id of the updated Account, if exactly one matched.')
        public Id accountId;
    }

    @InvocableMethod(
        label='Update Account Fields'
        description='Updates the Rating, Industry, Type and/or Annual Revenue of a single existing Account identified by Id or name, and records the change in the change log. Revenue changes involving more than $100M are sent to the user\'s manager for approval instead.'
        category='Account Management')
    public static List<Response> updateAccounts(List<Request> requests) {
        Set<Id> accountIds = new Set<Id>();
        List<String> patterns = new List<String>();
        for (Request req : requests) {
            Id accountId = AgentInputValidation.accountId(req.accountId);
            if (accountId != null) {
                accountIds.add(accountId);
            } else if (String.isNotBlank(req.accountName)) {
                patterns.add('%' + req.accountName.trim() + '%');
            }
        }

        Map<Id, Account> accountsById = accountIds.isEmpty()
            ? new Map<Id, Account>()
            : new Map<Id, Account>([SELECT Id, Name, Rating, Industry, Type, AnnualRevenue
                                    FROM Account
                                    WHERE Id IN :accountIds
                                    WITH USER_MODE]);

        List<Account> nameCandidates = patterns.isEmpty()
            ? new List<Account>()
            : [SELECT Id, Name, Rating, Industry, Type, AnnualRevenue
               FROM Account
               WHERE Name LIKE :patterns
               WITH USER_MODE
               LIMIT 200];

        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            responses.add(processRequest(req, accountsById, nameCandidates));
        }
        return responses;
    }

    private static Response processRequest(Request req, Map<Id, Account> accountsById, List<Account> nameCandidates) {
        Account acc;
        Id accountId = AgentInputValidation.accountId(req.accountId);
        if (accountId != null) {
            acc = accountsById.get(accountId);
            if (acc == null) {
                return fail('I could not find that account, or you do not have access to it.');
            }
        } else if (String.isNotBlank(req.accountName)) {
            List<Account> matches = findMatches(req.accountName.trim(), nameCandidates);
            if (matches.isEmpty()) {
                return fail('I could not find an account matching "' + req.accountName + '".');
            }
            if (matches.size() > 1) {
                List<String> names = new List<String>();
                for (Account a : matches) {
                    names.add(a.Name);
                }
                return fail('More than one account matches "' + req.accountName + '": '
                    + String.join(names, ', ') + '. Which one did you mean?');
            }
            acc = matches[0];
        } else if (String.isNotBlank(req.accountId)) {
            return fail('"' + req.accountId + '" is not an Account Id. Which account should I update?');
        } else {
            return fail('Please tell me which account to update.');
        }

        if (String.isBlank(req.rating) && String.isBlank(req.industry) && String.isBlank(req.accountType)
                && req.annualRevenue == null) {
            return fail('No new values were provided for ' + acc.Name + '. I can update Rating, Industry, Type or Annual Revenue.');
        }

        Account toUpdate = new Account(Id = acc.Id);
        List<Agent_Change_Log__c> changes = new List<Agent_Change_Log__c>();
        try {
            stage(acc, toUpdate, changes, Account.Rating, picklistValue(Account.Rating, req.rating), req.originalRequest);
            stage(acc, toUpdate, changes, Account.Industry, picklistValue(Account.Industry, req.industry), req.originalRequest);
            stage(acc, toUpdate, changes, Account.Type, picklistValue(Account.Type, req.accountType), req.originalRequest);
        } catch (AgentInputValidation.InvalidValueException e) {
            return fail(e.getMessage());
        }

        Agent_Change_Log__c revenueForApproval;
        if (req.annualRevenue != null) {
            if (req.annualRevenue < 0) {
                return fail('Annual revenue cannot be negative.');
            }
            if (req.annualRevenue != acc.AnnualRevenue && needsApproval(acc.AnnualRevenue, req.annualRevenue)) {
                revenueForApproval = AgentChangeLog.entry(acc, Account.AnnualRevenue, req.annualRevenue, req.originalRequest);
                revenueForApproval.Status__c = AgentChangeLog.STATUS_PENDING;
            } else {
                stage(acc, toUpdate, changes, Account.AnnualRevenue, req.annualRevenue, req.originalRequest);
            }
        }
        if (changes.isEmpty() && revenueForApproval == null) {
            return fail(acc.Name + ' already has those values, so nothing changed.');
        }

        Response res = new Response();
        res.accountId = acc.Id;
        res.success = false;
        res.pendingApproval = false;
        List<String> messages = new List<String>();
        if (!changes.isEmpty()) {
            Savepoint sp = Database.setSavepoint();
            try {
                Database.update(toUpdate, true, AccessLevel.USER_MODE);
                Database.insert(changes, AccessLevel.SYSTEM_MODE);
            } catch (Exception e) {
                Database.rollback(sp);
                return fail('Salesforce rejected the update to ' + acc.Name + ': ' + e.getMessage());
            }
            res.success = true;
            messages.add('Updated ' + acc.Name + ' (' + AgentChangeLog.describe(changes) + ').');
        }
        if (revenueForApproval != null) {
            messages.add(submitForApproval(acc, revenueForApproval, res));
        }
        res.message = String.join(messages, ' ');
        return res;
    }

    private static Boolean needsApproval(Decimal currentRevenue, Decimal newRevenue) {
        return newRevenue > APPROVAL_THRESHOLD || (currentRevenue != null && currentRevenue > APPROVAL_THRESHOLD);
    }

    private static String picklistValue(Schema.SObjectField field, String value) {
        return String.isBlank(value) ? null : AgentInputValidation.picklistValue(field, value);
    }

    /** Adds a field change to the update and the change log, skipping values that wouldn't change. */
    private static void stage(Account acc, Account toUpdate, List<Agent_Change_Log__c> changes,
            Schema.SObjectField field, Object newValue, String request) {
        if (newValue == null || newValue == acc.get(field)) {
            return;
        }
        toUpdate.put(field, newValue);
        changes.add(AgentChangeLog.entry(acc, field, newValue, request));
    }

    /**
     * Logs a revenue change as Pending Approval and submits it to the user's
     * manager. AgentChangeLog makes the change if the manager approves it.
     */
    private static String submitForApproval(Account acc, Agent_Change_Log__c change, Response res) {
        List<Agent_Change_Log__c> waiting = [SELECT Name
                                             FROM Agent_Change_Log__c
                                             WHERE Account__c = :acc.Id
                                             AND Field__c = :change.Field__c
                                             AND Status__c = :AgentChangeLog.STATUS_PENDING
                                             WITH SYSTEM_MODE
                                             LIMIT 1];
        if (!waiting.isEmpty()) {
            return 'A revenue change for ' + acc.Name + ' is already waiting for approval ('
                + waiting[0].Name + '), so I did not submit another one.';
        }

        Savepoint sp = Database.setSavepoint();
        String error;
        try {
            Database.insert(change, AccessLevel.SYSTEM_MODE);
            Approval.ProcessSubmitRequest submission = new Approval.ProcessSubmitRequest();
            submission.setObjectId(change.Id);
            submission.setProcessDefinitionNameOrId(AgentChangeLog.APPROVAL_PROCESS);
            submission.setComments(String.isBlank(change.Original_Request__c)
                ? 'Requested through Account Assistant.'
                : ('Requested through Account Assistant: "' + change.Original_Request__c + '"').abbreviate(4000));
            Approval.ProcessResult result = Approval.process(submission, false);
            if (result.isSuccess()) {
                res.success = true;
                res.pendingApproval = true;
                return 'Revenue changes involving more than $100M need manager approval, so I sent '
                    + AgentChangeLog.describe(new List<Agent_Change_Log__c>{ change }) + ' to '
                    + approverNames(result.getActorIds()) + ' for approval ('
                    + [SELECT Name FROM Agent_Change_Log__c WHERE Id = :change.Id WITH SYSTEM_MODE].Name
                    + '). It will not be applied until they approve it.';
            }
            error = result.getErrors()[0].getStatusCode() + ': ' + result.getErrors()[0].getMessage();
        } catch (Exception e) {
            error = e.getMessage();
        }
        Database.rollback(sp);
        if (error.contains('MANAGER_NOT_DEFINED')) {
            return 'Revenue changes involving more than $100M need a manager\'s approval, but you have no manager set '
                + 'in Salesforce, so I did not change the annual revenue. Ask your Salesforce admin to set your Manager.';
        }
        return 'I could not send the revenue change for approval, so I did not change the annual revenue (' + error + ').';
    }

    private static String approverNames(List<Id> userIds) {
        List<String> names = new List<String>();
        for (User approver : [SELECT Name FROM User WHERE Id IN :userIds]) {
            names.add(approver.Name);
        }
        return names.isEmpty() ? 'your manager' : String.join(names, ', ');
    }

    /** Exact (case-insensitive) match wins; otherwise fall back to "contains". */
    private static List<Account> findMatches(String name, List<Account> candidates) {
        List<Account> partial = new List<Account>();
        for (Account a : candidates) {
            if (a.Name.equalsIgnoreCase(name)) {
                return new List<Account>{ a };
            }
            if (a.Name.containsIgnoreCase(name)) {
                partial.add(a);
            }
        }
        return partial;
    }

    private static Response fail(String message) {
        Response res = new Response();
        res.success = false;
        res.pendingApproval = false;
        res.message = message;
        return res;
    }
}
