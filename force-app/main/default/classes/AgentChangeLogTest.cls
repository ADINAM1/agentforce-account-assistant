@IsTest
private class AgentChangeLogTest {

    private static final String REQUEST = 'Make Test Energy Hot and set its revenue to 150 million';

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User manager = newUser('manager', null);
            insert manager;
            List<User> users = new List<User>{ manager, newUser('rep', manager.Id), newUser('solo', null) };
            insert new List<User>{ users[1], users[2] };
            // Read-only access to the change log, as Account_Assistant_User grants. Built here rather than
            // assigned so the tests don't depend on that permission set, which is deployed after the agent.
            PermissionSet logReader = new PermissionSet(Name = 'Test_Change_Log_Reader', Label = 'Test Change Log Reader');
            insert logReader;
            insert new ObjectPermissions(ParentId = logReader.Id, SobjectType = 'Agent_Change_Log__c', PermissionsRead = true);
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (User u : users) {
                assignments.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = logReader.Id));
            }
            insert assignments;
        }
        insert new List<Account>{
            new Account(Name = 'Test Energy', Rating = 'Warm', Industry = 'Energy', AnnualRevenue = 60000000),
            new Account(Name = 'Test Megacorp', Rating = 'Hot', AnnualRevenue = 140000000)
        };
    }

    private static User newUser(String role, Id managerId) {
        String unique = role + Math.abs(Crypto.getRandomInteger());
        return new User(
            Alias = role.left(8),
            Email = unique + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LastName = 'Test ' + role,
            LocaleSidKey = 'en_US',
            ManagerId = managerId,
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User'].Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = unique + '@agentchangelog.test');
    }

    private static User user(String role) {
        return [SELECT Id FROM User WHERE LastName = :('Test ' + role) LIMIT 1];
    }

    private static UpdateAccountAction.Request request(String accountName) {
        UpdateAccountAction.Request req = new UpdateAccountAction.Request();
        req.accountName = accountName;
        req.originalRequest = REQUEST;
        return req;
    }

    private static UpdateAccountAction.Response runAs(String role, UpdateAccountAction.Request req) {
        UpdateAccountAction.Response res;
        System.runAs(user(role)) {
            res = UpdateAccountAction.updateAccounts(new List<UpdateAccountAction.Request>{ req })[0];
        }
        return res;
    }

    private static List<Agent_Change_Log__c> entries(String status) {
        return [SELECT Id, Field__c, Old_Value__c, New_Value__c, Original_Request__c, Status__c, CreatedById, Reviewed_By__c
                FROM Agent_Change_Log__c
                WHERE Status__c = :status
                ORDER BY Name];
    }

    /** The manager approves or rejects the pending change. */
    private static void decide(String action) {
        Approval.ProcessWorkitemRequest decision = new Approval.ProcessWorkitemRequest();
        decision.setWorkitemId([SELECT Id FROM ProcessInstanceWorkitem
                                WHERE ProcessInstance.TargetObjectId = :entries(AgentChangeLog.STATUS_PENDING)[0].Id].Id);
        decision.setAction(action);
        System.runAs(user('manager')) {
            Assert.isTrue(Approval.process(decision).isSuccess());
        }
    }

    private static Decimal revenueOf(String accountName) {
        return [SELECT AnnualRevenue FROM Account WHERE Name = :accountName].AnnualRevenue;
    }

    @IsTest
    static void logsEveryAppliedChange() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.rating = 'hot';
        req.annualRevenue = 90000000;

        Test.startTest();
        UpdateAccountAction.Response res = runAs('rep', req);
        Test.stopTest();

        Assert.isTrue(res.success, res.message);
        Assert.isFalse(res.pendingApproval, 'Revenue stays under $100M, so no approval is needed');
        List<Agent_Change_Log__c> applied = entries(AgentChangeLog.STATUS_APPLIED);
        Assert.areEqual(2, applied.size(), 'One entry per changed field');
        Assert.areEqual('Rating', applied[0].Field__c);
        Assert.areEqual('Warm', applied[0].Old_Value__c);
        Assert.areEqual('Hot', applied[0].New_Value__c);
        Assert.areEqual('AnnualRevenue', applied[1].Field__c);
        Assert.areEqual('60000000', applied[1].Old_Value__c);
        Assert.areEqual('90000000', applied[1].New_Value__c);
        Assert.areEqual(REQUEST, applied[0].Original_Request__c);
        Assert.areEqual(user('rep').Id, applied[0].CreatedById, 'The log records the real user');
    }

    @IsTest
    static void skipsValuesThatWouldNotChange() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.rating = 'Warm';

        UpdateAccountAction.Response res = runAs('rep', req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('already has those values'), res.message);
        Assert.areEqual(0, [SELECT COUNT() FROM Agent_Change_Log__c]);
    }

    @IsTest
    static void bigRevenueChangeWaitsForManagerApproval() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.rating = 'Hot';
        req.annualRevenue = 150000000;

        Test.startTest();
        UpdateAccountAction.Response res = runAs('rep', req);
        Test.stopTest();

        Assert.isTrue(res.success, res.message);
        Assert.isTrue(res.pendingApproval);
        Assert.isTrue(res.message.contains('Test manager'), 'Names the approver: ' + res.message);
        Account acc = [SELECT Rating, AnnualRevenue FROM Account WHERE Name = 'Test Energy'];
        Assert.areEqual('Hot', acc.Rating, 'Changes that need no approval are applied right away');
        Assert.areEqual(60000000, acc.AnnualRevenue, 'The revenue change waits for approval');
        Agent_Change_Log__c pending = entries(AgentChangeLog.STATUS_PENDING)[0];
        Assert.areEqual('150000000', pending.New_Value__c);
        Assert.areEqual(user('manager').Id,
            [SELECT ActorId FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :pending.Id].ActorId,
            'Routed to the requester\'s manager');
    }

    @IsTest
    static void changesToRevenueOverThresholdNeedApprovalEvenWhenSmall() {
        UpdateAccountAction.Request req = request('Test Megacorp');
        req.annualRevenue = 130000000;

        UpdateAccountAction.Response res = runAs('rep', req);

        Assert.isTrue(res.pendingApproval, res.message);
        Assert.areEqual(140000000, revenueOf('Test Megacorp'));
    }

    @IsTest
    static void approvalAppliesTheChange() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.annualRevenue = 150000000;
        runAs('rep', req);

        Test.startTest();
        decide('Approve');
        Test.stopTest();

        Assert.areEqual(150000000, revenueOf('Test Energy'));
        Agent_Change_Log__c entry = [SELECT Status__c, Reviewed_By__c FROM Agent_Change_Log__c];
        Assert.areEqual(AgentChangeLog.STATUS_APPLIED, entry.Status__c);
        Assert.areEqual(user('manager').Id, entry.Reviewed_By__c);
    }

    @IsTest
    static void rejectionLeavesTheAccountUnchanged() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.annualRevenue = 150000000;
        runAs('rep', req);

        Test.startTest();
        decide('Reject');
        Test.stopTest();

        Assert.areEqual(60000000, revenueOf('Test Energy'));
        Agent_Change_Log__c entry = [SELECT Status__c, Reviewed_By__c FROM Agent_Change_Log__c];
        Assert.areEqual(AgentChangeLog.STATUS_REJECTED, entry.Status__c);
        Assert.areEqual(user('manager').Id, entry.Reviewed_By__c);
    }

    @IsTest
    static void submitsOneRevenueApprovalAtATime() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.annualRevenue = 150000000;
        runAs('rep', req);
        req.annualRevenue = 160000000;

        UpdateAccountAction.Response res = runAs('rep', req);

        Assert.isFalse(res.success);
        Assert.isTrue(res.message.contains('already waiting for approval'), res.message);
        Assert.areEqual(1, [SELECT COUNT() FROM Agent_Change_Log__c]);
    }

    @IsTest
    static void explainsWhenUserHasNoManager() {
        UpdateAccountAction.Request req = request('Test Energy');
        req.annualRevenue = 150000000;

        UpdateAccountAction.Response res = runAs('solo', req);

        Assert.isFalse(res.success);
        Assert.isFalse(res.pendingApproval);
        Assert.isTrue(res.message.contains('no manager'), res.message);
        Assert.areEqual(0, [SELECT COUNT() FROM Agent_Change_Log__c], 'Nothing is left pending');
        Assert.areEqual(60000000, revenueOf('Test Energy'));
    }
}
