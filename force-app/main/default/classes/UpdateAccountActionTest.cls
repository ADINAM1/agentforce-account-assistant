@IsTest
private class UpdateAccountActionTest {

    @TestSetup
    static void setup() {
        insert new List<Account>{
            new Account(Name = 'Test Robotics', Rating = 'Cold', Industry = 'Manufacturing', Type = 'Prospect'),
            new Account(Name = 'Test Health East'),
            new Account(Name = 'Test Health West')
        };
    }

    private static UpdateAccountAction.Response run(UpdateAccountAction.Request req) {
        return UpdateAccountAction.updateAccounts(new List<UpdateAccountAction.Request>{ req })[0];
    }

    @IsTest
    static void updatesFieldsOnExactMatch() {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = 'test robotics';
        req.rating = 'hot';
        req.industry = 'Technology';
        req.accountType = 'Customer - Direct';
        req.annualRevenue = 1000000;

        Test.startTest();
        UpdateAccountAction.Response res = run(req);
        Test.stopTest();

        Assert.isTrue(res.success, res.message);
        Account acc = [SELECT Rating, Industry, Type, AnnualRevenue FROM Account WHERE Id = :res.accountId];
        Assert.areEqual('Hot', acc.Rating, 'Picklist value should be normalized to canonical case');
        Assert.areEqual('Technology', acc.Industry);
        Assert.areEqual('Customer - Direct', acc.Type);
        Assert.areEqual(1000000, acc.AnnualRevenue);
    }

    @IsTest
    static void asksWhenNameIsAmbiguous() {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = 'Test Health';
        req.rating = 'Warm';

        UpdateAccountAction.Response res = run(req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('Test Health East') && res.message.contains('Test Health West'), res.message);
    }

    @IsTest
    static void rejectsInvalidPicklistValue() {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = 'Test Robotics';
        req.rating = 'Super Hot';

        UpdateAccountAction.Response res = run(req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('Allowed values'), res.message);
        Assert.areEqual('Cold', [SELECT Rating FROM Account WHERE Name = 'Test Robotics'].Rating);
    }

    @IsTest
    static void reportsMissingAccount() {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = 'Nonexistent Corp';
        req.rating = 'Hot';

        UpdateAccountAction.Response res = run(req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('could not find'), res.message);
    }

    @IsTest
    static void requiresAtLeastOneChange() {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = 'Test Robotics';

        UpdateAccountAction.Response res = run(req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('No new values'), res.message);
    }

    @IsTest
    static void rejectsNegativeRevenue() {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = 'Test Robotics';
        req.annualRevenue = -5;

        UpdateAccountAction.Response res = run(req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('negative'), res.message);
    }
}
