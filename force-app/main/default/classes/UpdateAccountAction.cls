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
 *  - Bulkified (one query per lookup style for all requests), as invocable
 *    methods may be called with multiple requests.
 */
public with sharing class UpdateAccountAction {

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
    }

    public class Response {
        @InvocableVariable(label='Success' description='True if the Account was updated.')
        public Boolean success;

        @InvocableVariable(label='Message' description='Human-readable result to relay to the user, including what changed or why nothing changed.')
        public String message;

        @InvocableVariable(label='Account Id' description='Id of the updated Account, if exactly one matched.')
        public Id accountId;
    }

    @InvocableMethod(
        label='Update Account Fields'
        description='Updates the Rating, Industry, Type and/or Annual Revenue of a single existing Account identified by Id or name. Use when the user asks to change, set or update one of these fields on an account.'
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

        Account toUpdate = new Account(Id = acc.Id);
        List<String> changes = new List<String>();

        try {
            if (String.isNotBlank(req.rating)) {
                toUpdate.Rating = AgentInputValidation.picklistValue(Account.Rating, req.rating);
                changes.add('Rating: ' + acc.Rating + ' → ' + toUpdate.Rating);
            }
            if (String.isNotBlank(req.industry)) {
                toUpdate.Industry = AgentInputValidation.picklistValue(Account.Industry, req.industry);
                changes.add('Industry: ' + acc.Industry + ' → ' + toUpdate.Industry);
            }
            if (String.isNotBlank(req.accountType)) {
                toUpdate.Type = AgentInputValidation.picklistValue(Account.Type, req.accountType);
                changes.add('Type: ' + acc.Type + ' → ' + toUpdate.Type);
            }
        } catch (AgentInputValidation.InvalidValueException e) {
            return fail(e.getMessage());
        }
        if (req.annualRevenue != null) {
            if (req.annualRevenue < 0) {
                return fail('Annual revenue cannot be negative.');
            }
            toUpdate.AnnualRevenue = req.annualRevenue;
            changes.add('Annual Revenue: ' + acc.AnnualRevenue + ' → ' + req.annualRevenue);
        }

        if (changes.isEmpty()) {
            return fail('No new values were provided for ' + acc.Name + '. I can update Rating, Industry, Type or Annual Revenue.');
        }

        try {
            Database.update(toUpdate, true, AccessLevel.USER_MODE);
        } catch (Exception e) {
            return fail('Salesforce rejected the update to ' + acc.Name + ': ' + e.getMessage());
        }

        Response res = new Response();
        res.success = true;
        res.accountId = acc.Id;
        res.message = 'Updated ' + acc.Name + ' (' + String.join(changes, '; ') + ').';
        return res;
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
        res.message = message;
        return res;
    }
}
