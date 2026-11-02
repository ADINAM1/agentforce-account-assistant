trigger AgentChangeLogTrigger on Agent_Change_Log__c (before update) {
    AgentChangeLog.applyApprovalDecisions(Trigger.new, Trigger.oldMap);
}
