@IsTest
private class FindAccountsActionTest {

    @TestSetup
    static void setup() {
        insert new List<Account>{
            new Account(Name = 'Orion', Rating = 'Hot', Industry = 'Finance', Type = 'Customer - Direct', AnnualRevenue = 90000000),
            new Account(Name = 'Orion Labs', Rating = 'Hot', Industry = 'Technology', Type = 'Prospect', AnnualRevenue = 30000000),
            new Account(Name = 'Polaris Bank', Rating = 'Cold', Industry = 'Finance', Type = 'Prospect', AnnualRevenue = 5000000,
                Description = 'Evaluating a new CRM')
        };
        Account polaris = [SELECT Id FROM Account WHERE Name = 'Polaris Bank'];
        insert new Opportunity(Name = 'Polaris CRM Rollout', AccountId = polaris.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30), Amount = 250000);
        insert new Task(Subject = 'Send security questionnaire', WhatId = polaris.Id, Status = 'Not Started',
            Priority = 'High', ActivityDate = Date.today().addDays(3));
    }

    private static FindAccountsAction.Response run(FindAccountsAction.Request req) {
        return FindAccountsAction.findAccounts(new List<FindAccountsAction.Request>{ req })[0];
    }

    @IsTest
    static void returnsProfileWithRelatedRecordsForSingleMatch() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.accountName = 'polaris';

        Test.startTest();
        FindAccountsAction.Response res = run(req);
        Test.stopTest();

        Assert.areEqual(1, res.matchCount, res.summary);
        Assert.areEqual([SELECT Id FROM Account WHERE Name = 'Polaris Bank'].Id, res.accountId);
        Assert.isTrue(res.summary.contains('Evaluating a new CRM'), res.summary);
        Assert.isTrue(res.summary.contains('Polaris CRM Rollout'), res.summary);
        Assert.isTrue(res.summary.contains('Send security questionnaire'), res.summary);
    }

    @IsTest
    static void profileIncludesRecentAgentChanges() {
        Account polaris = [SELECT Id FROM Account WHERE Name = 'Polaris Bank'];
        insert new Agent_Change_Log__c(Account__c = polaris.Id, Field__c = 'Rating', Old_Value__c = 'Cold',
            New_Value__c = 'Warm', Status__c = 'Applied', Original_Request__c = 'Make Polaris Warm');
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.accountId = polaris.Id;

        FindAccountsAction.Response res = run(req);

        Assert.isTrue(res.summary.contains('Rating: Cold → Warm | Applied | requested by ' + UserInfo.getName()), res.summary);
    }

    @IsTest
    static void prefersExactNameOverPartialMatches() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.accountName = 'orion';

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(1, res.matchCount, res.summary);
        Assert.isTrue(res.summary.startsWith('Orion (Id:'), res.summary);
    }

    @IsTest
    static void listsAccountsMatchingFilters() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.rating = 'hot';

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(2, res.matchCount, res.summary);
        Assert.isNull(res.accountId, 'No single account Id when several match');
        Assert.isTrue(res.summary.indexOf('Orion |') < res.summary.indexOf('Orion Labs |'), 'Sorted by revenue: ' + res.summary);
    }

    @IsTest
    static void combinesPicklistAndRevenueFilters() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.industry = 'Finance';
        req.minAnnualRevenue = 10000000;

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(1, res.matchCount, res.summary);
        Assert.isTrue(res.summary.startsWith('Orion (Id:'), res.summary);
    }

    @IsTest
    static void capsResultsAndSaysMoreExist() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.maxAnnualRevenue = 100000000;
        req.maxResults = 2;

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(2, res.matchCount, res.summary);
        Assert.isTrue(res.summary.contains('more exist'), res.summary);
    }

    @IsTest
    static void findsByAccountId() {
        Account polaris = [SELECT Id FROM Account WHERE Name = 'Polaris Bank'];
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.accountId = polaris.Id;

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(polaris.Id, res.accountId);
    }

    @IsTest
    static void rejectsIdThatIsNotAnAccount() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.accountId = UserInfo.getUserId();

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(0, res.matchCount);
        Assert.isTrue(res.summary.contains('is not an Account Id'), res.summary);
    }

    @IsTest
    static void rejectsInvalidPicklistFilter() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.rating = 'Super Hot';

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(0, res.matchCount);
        Assert.isTrue(res.summary.contains('Allowed values'), res.summary);
    }

    @IsTest
    static void reportsNoMatches() {
        FindAccountsAction.Request req = new FindAccountsAction.Request();
        req.accountName = 'Orion';
        req.billingState = 'Nowhere';

        FindAccountsAction.Response res = run(req);

        Assert.areEqual(0, res.matchCount);
        Assert.areEqual('No accounts match those criteria.', res.summary);
    }
}
