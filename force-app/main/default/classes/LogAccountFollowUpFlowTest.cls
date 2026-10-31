@IsTest
private class LogAccountFollowUpFlowTest {

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Vega Systems');
    }

    private static Flow.Interview run(Map<String, Object> inputs) {
        Flow.Interview interview = Flow.Interview.createInterview('Log_Account_Follow_Up', inputs);
        interview.start();
        return interview;
    }

    @IsTest
    static void createsTaskOnAccount() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Vega Systems'];
        Date due = Date.today().addDays(7);

        Test.startTest();
        Flow.Interview interview = run(new Map<String, Object>{
            'accountId' => acc.Id,
            'subject' => 'Send EU pricing proposal',
            'comments' => 'Include volume discounts',
            'dueDate' => due,
            'priority' => 'High'
        });
        Test.stopTest();

        String taskId = (String) interview.getVariableValue('taskId');
        Task created = [SELECT Subject, Description, Priority, Status, ActivityDate, WhatId FROM Task WHERE Id = :taskId];
        Assert.areEqual(acc.Id, created.WhatId);
        Assert.areEqual('Send EU pricing proposal', created.Subject);
        Assert.areEqual('Include volume discounts', created.Description);
        Assert.areEqual('High', created.Priority);
        Assert.areEqual('Not Started', created.Status);
        Assert.areEqual(due, created.ActivityDate);
        String message = (String) interview.getVariableValue('message');
        Assert.isTrue(message.contains('Vega Systems') && message.contains('High priority'), message);
    }

    @IsTest
    static void defaultsToNormalPriorityAndNoDueDate() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Vega Systems'];

        Flow.Interview interview = run(new Map<String, Object>{
            'accountId' => acc.Id,
            'subject' => 'Check in after demo'
        });

        Task created = [SELECT Priority, ActivityDate FROM Task WHERE WhatId = :acc.Id];
        Assert.areEqual('Normal', created.Priority);
        Assert.isNull(created.ActivityDate);
        String message = (String) interview.getVariableValue('message');
        Assert.isTrue(message.contains('no due date'), message);
    }

    @IsTest
    static void reportsMissingAccount() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Vega Systems'];
        delete acc;

        Flow.Interview interview = run(new Map<String, Object>{
            'accountId' => acc.Id,
            'subject' => 'Orphaned follow-up'
        });

        Assert.isNull(interview.getVariableValue('taskId'));
        Assert.isTrue(((String) interview.getVariableValue('message')).contains('could not find'));
        Assert.areEqual(0, [SELECT COUNT() FROM Task]);
    }

    @IsTest
    static void reportsInvalidIdInsteadOfFailing() {
        Flow.Interview interview = run(new Map<String, Object>{
            'accountId' => 'not-an-id',
            'subject' => 'Bad input'
        });

        String message = (String) interview.getVariableValue('message');
        Assert.isNull(interview.getVariableValue('taskId'));
        Assert.isTrue(message.contains('could not be logged') || message.contains('could not find'), message);
        Assert.areEqual(0, [SELECT COUNT() FROM Task]);
    }
}
