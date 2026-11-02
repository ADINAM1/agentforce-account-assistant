// Demo fallback: approves the newest pending Revenue Change Approval as the
// running admin, for when you can't log in as the manager. The change log
// entry's Reviewed By then shows the admin instead of the manager.
//   sf apex run --file scripts/apex/approve-pending-revenue-change.apex
ProcessInstanceWorkitem workitem = [
    SELECT Id, ProcessInstance.TargetObjectId
    FROM ProcessInstanceWorkitem
    WHERE ProcessInstance.ProcessDefinition.DeveloperName = 'Revenue_Change_Approval'
    ORDER BY CreatedDate DESC
    LIMIT 1
];
Approval.ProcessWorkitemRequest decision = new Approval.ProcessWorkitemRequest();
decision.setWorkitemId(workitem.Id);
decision.setAction('Approve');
decision.setComments('Approved by an admin on the manager\'s behalf');
Approval.process(decision);
Agent_Change_Log__c entry = [SELECT Name, Status__c FROM Agent_Change_Log__c WHERE Id = :workitem.ProcessInstance.TargetObjectId];
System.debug(LoggingLevel.ERROR, entry.Name + ' is now ' + entry.Status__c);
