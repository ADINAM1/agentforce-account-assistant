/**
 * Agentforce custom action: finds Accounts by Id, name and/or filters and
 * returns a plain-text summary for the agent to answer from.
 *
 * Design notes:
 *  - Runs in USER_MODE, so results respect the user's sharing and field access.
 *  - One match returns a profile (including open opportunities, recent
 *    follow-up tasks and recent changes made through the agent); several
 *    matches return a compact list.
 *  - Filters are bind variables (Database.queryWithBinds), never concatenated
 *    into the query, and picklist filters are validated against the schema.
 *  - Each request runs its own query because every request carries different
 *    filters; agents invoke this action with one request at a time.
 */
public with sharing class FindAccountsAction {

    private static final Integer DEFAULT_MAX_RESULTS = 10;
    private static final Integer MAX_RESULTS_CAP = 25;
    private static final String ACCOUNT_FIELDS = 'Id, Name, Industry, Rating, Type, AnnualRevenue, NumberOfEmployees, '
        + 'BillingCity, BillingState, Phone, Website, Description, Owner.Name';

    public class Request {
        @InvocableVariable(
            label='Account Id'
            description='Salesforce Id of a specific Account (starts with 001), e.g. the record the user is viewing.')
        public String accountId;

        @InvocableVariable(
            label='Account Name'
            description='Full or partial account name to search for, e.g. "Acme".')
        public String accountName;

        @InvocableVariable(
            label='Rating'
            description='Only return accounts with this rating. Allowed values: Hot, Warm, Cold.')
        public String rating;

        @InvocableVariable(
            label='Industry'
            description='Only return accounts in this industry, e.g. Finance, Technology, Healthcare, Retail, Energy.')
        public String industry;

        @InvocableVariable(
            label='Type'
            description='Only return accounts of this type, e.g. Prospect, Customer - Direct, Customer - Channel.')
        public String accountType;

        @InvocableVariable(
            label='Billing State'
            description='Only return accounts billed in this US state, as the full state name, e.g. California.')
        public String billingState;

        @InvocableVariable(
            label='Minimum Annual Revenue'
            description='Only return accounts with annual revenue at or above this amount in US dollars, e.g. 50000000 for $50M.')
        public Decimal minAnnualRevenue;

        @InvocableVariable(
            label='Maximum Annual Revenue'
            description='Only return accounts with annual revenue at or below this amount in US dollars.')
        public Decimal maxAnnualRevenue;

        @InvocableVariable(
            label='Max Results'
            description='Maximum number of accounts to return (default 10, at most 25).')
        public Integer maxResults;
    }

    public class Response {
        @InvocableVariable(label='Summary' description='Plain-text details of the matching accounts, or why none matched.')
        public String summary;

        @InvocableVariable(label='Match Count' description='Number of accounts returned.')
        public Integer matchCount;

        @InvocableVariable(label='Account Id' description='Id of the account when exactly one matched; use it for follow-up actions.')
        public String accountId;
    }

    @InvocableMethod(
        label='Find Accounts'
        description='Finds Accounts by Id or name and/or by Rating, Industry, Type, billing state or annual revenue range. Returns a profile when one account matches, or a list when several match.'
        category='Account Management')
    public static List<Response> findAccounts(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            responses.add(find(req));
        }
        return responses;
    }

    private static Response find(Request req) {
        List<String> conditions = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();

        if (String.isNotBlank(req.accountId)) {
            Id accountId = AgentInputValidation.accountId(req.accountId);
            if (accountId == null) {
                return result('"' + req.accountId + '" is not an Account Id.', new List<Account>());
            }
            conditions.add('Id = :accountId');
            binds.put('accountId', accountId);
        }
        if (String.isNotBlank(req.accountName)) {
            conditions.add('Name LIKE :namePattern');
            binds.put('namePattern', '%' + req.accountName.trim() + '%');
        }
        try {
            addPicklistFilter(conditions, binds, Account.Rating, 'rating', req.rating);
            addPicklistFilter(conditions, binds, Account.Industry, 'industry', req.industry);
            addPicklistFilter(conditions, binds, Account.Type, 'accountType', req.accountType);
        } catch (AgentInputValidation.InvalidValueException e) {
            return result(e.getMessage(), new List<Account>());
        }
        if (String.isNotBlank(req.billingState)) {
            conditions.add('BillingState = :billingState');
            binds.put('billingState', req.billingState.trim());
        }
        if (req.minAnnualRevenue != null) {
            conditions.add('AnnualRevenue >= :minRevenue');
            binds.put('minRevenue', req.minAnnualRevenue);
        }
        if (req.maxAnnualRevenue != null) {
            conditions.add('AnnualRevenue <= :maxRevenue');
            binds.put('maxRevenue', req.maxAnnualRevenue);
        }

        Integer maxResults = req.maxResults == null || req.maxResults < 1
            ? DEFAULT_MAX_RESULTS
            : Math.min(req.maxResults, MAX_RESULTS_CAP);

        // Fetch one extra row to know whether more accounts match than are shown.
        String soql = 'SELECT ' + ACCOUNT_FIELDS + ' FROM Account'
            + (conditions.isEmpty() ? '' : ' WHERE ' + String.join(conditions, ' AND '))
            + ' ORDER BY AnnualRevenue DESC NULLS LAST, Name LIMIT ' + (maxResults + 1);
        List<Account> accounts = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);

        if (String.isNotBlank(req.accountName)) {
            accounts = preferExactName(req.accountName.trim(), accounts);
        }
        if (accounts.isEmpty()) {
            return result('No accounts match those criteria.', accounts);
        }
        if (accounts.size() == 1) {
            return result(profile(accounts[0]), accounts);
        }

        Boolean hasMore = accounts.size() > maxResults;
        List<Account> shown = new List<Account>();
        List<String> lines = new List<String>{
            hasMore
                ? 'Showing the first ' + maxResults + ' matching accounts, sorted by annual revenue (more exist; add filters to narrow down):'
                : 'Found ' + accounts.size() + ' matching accounts, sorted by annual revenue:'
        };
        for (Account acc : accounts) {
            if (shown.size() == maxResults) {
                break;
            }
            shown.add(acc);
            lines.add(listLine(acc));
        }
        return result(String.join(lines, '\n'), shown);
    }

    private static void addPicklistFilter(List<String> conditions, Map<String, Object> binds,
            Schema.SObjectField field, String bindName, String value) {
        if (String.isBlank(value)) {
            return;
        }
        conditions.add(field.getDescribe().getName() + ' = :' + bindName);
        binds.put(bindName, AgentInputValidation.picklistValue(field, value));
    }

    /** An exact (case-insensitive) name match wins over partial matches. */
    private static List<Account> preferExactName(String name, List<Account> accounts) {
        for (Account acc : accounts) {
            if (acc.Name.equalsIgnoreCase(name)) {
                return new List<Account>{ acc };
            }
        }
        return accounts;
    }

    private static String profile(Account acc) {
        List<String> lines = new List<String>{
            acc.Name + ' (Id: ' + acc.Id + ')',
            'Industry: ' + valueOrDash(acc.Industry) + ' | Type: ' + valueOrDash(acc.Type) + ' | Rating: ' + valueOrDash(acc.Rating),
            'Annual revenue: ' + money(acc.AnnualRevenue) + ' | Employees: ' + valueOrDash(acc.NumberOfEmployees),
            'Location: ' + location(acc) + ' | Phone: ' + valueOrDash(acc.Phone) + ' | Website: ' + valueOrDash(acc.Website),
            'Owner: ' + acc.Owner.Name,
            'Notes: ' + valueOrDash(acc.Description)
        };
        lines.addAll(openOpportunityLines(acc.Id));
        lines.addAll(followUpLines(acc.Id));
        lines.addAll(changeLogLines(acc.Id));
        return String.join(lines, '\n');
    }

    private static List<String> openOpportunityLines(Id accountId) {
        List<Opportunity> opportunities;
        try {
            opportunities = [SELECT Name, StageName, Amount, CloseDate
                             FROM Opportunity
                             WHERE AccountId = :accountId AND IsClosed = false
                             WITH USER_MODE
                             ORDER BY CloseDate
                             LIMIT 5];
        } catch (QueryException e) {
            return new List<String>{ 'Open opportunities: not available to you' };
        }
        if (opportunities.isEmpty()) {
            return new List<String>{ 'Open opportunities: none' };
        }
        List<String> lines = new List<String>{ 'Open opportunities:' };
        for (Opportunity opp : opportunities) {
            lines.add('- ' + opp.Name + ' | ' + opp.StageName + ' | ' + money(opp.Amount) + ' | closes ' + opp.CloseDate);
        }
        return lines;
    }

    private static List<String> followUpLines(Id accountId) {
        List<Task> tasks;
        try {
            tasks = [SELECT Subject, Status, Priority, ActivityDate
                     FROM Task
                     WHERE WhatId = :accountId
                     WITH USER_MODE
                     ORDER BY CreatedDate DESC
                     LIMIT 5];
        } catch (QueryException e) {
            return new List<String>{ 'Recent follow-ups: not available to you' };
        }
        if (tasks.isEmpty()) {
            return new List<String>{ 'Recent follow-ups: none' };
        }
        List<String> lines = new List<String>{ 'Recent follow-ups (newest first):' };
        for (Task t : tasks) {
            lines.add('- ' + t.Subject + ' | ' + t.Status + ' | ' + t.Priority + ' priority | '
                + (t.ActivityDate == null ? 'no due date' : 'due ' + t.ActivityDate));
        }
        return lines;
    }

    private static List<String> changeLogLines(Id accountId) {
        List<Agent_Change_Log__c> entries;
        try {
            entries = [SELECT Name, toLabel(Field__c), Old_Value__c, New_Value__c, Status__c,
                           CreatedBy.Name, CreatedDate, Reviewed_By__r.Name
                       FROM Agent_Change_Log__c
                       WHERE Account__c = :accountId
                       WITH USER_MODE
                       ORDER BY CreatedDate DESC, Name DESC
                       LIMIT 5];
        } catch (QueryException e) {
            return new List<String>{ 'Recent changes through Account Assistant: not available to you' };
        }
        if (entries.isEmpty()) {
            return new List<String>{ 'Recent changes through Account Assistant: none' };
        }
        List<String> lines = new List<String>{ 'Recent changes through Account Assistant (newest first):' };
        for (Agent_Change_Log__c entry : entries) {
            lines.add('- ' + entry.Name + ' | ' + entry.Field__c + ': ' + valueOrDash(entry.Old_Value__c) + ' → '
                + entry.New_Value__c + ' | ' + entry.Status__c + ' | requested by ' + entry.CreatedBy.Name
                + ' on ' + entry.CreatedDate.date()
                + (entry.Reviewed_By__c == null ? '' : ' | reviewed by ' + entry.Reviewed_By__r.Name));
        }
        return lines;
    }

    private static String listLine(Account acc) {
        return '- ' + acc.Name + ' | ' + valueOrDash(acc.Industry) + ' | ' + valueOrDash(acc.Rating) + ' | '
            + valueOrDash(acc.Type) + ' | ' + money(acc.AnnualRevenue) + ' | ' + location(acc);
    }

    private static String location(Account acc) {
        List<String> parts = new List<String>();
        for (String part : new List<String>{ acc.BillingCity, acc.BillingState }) {
            if (String.isNotBlank(part)) {
                parts.add(part);
            }
        }
        return parts.isEmpty() ? '-' : String.join(parts, ', ');
    }

    private static String money(Decimal value) {
        return value == null ? '-' : '$' + value.setScale(0).format();
    }

    private static String valueOrDash(Object value) {
        return value == null || String.isBlank(String.valueOf(value)) ? '-' : String.valueOf(value);
    }

    private static Response result(String summary, List<Account> accounts) {
        Response res = new Response();
        res.summary = summary;
        res.matchCount = accounts.size();
        res.accountId = accounts.size() == 1 ? accounts[0].Id : null;
        return res;
    }
}
