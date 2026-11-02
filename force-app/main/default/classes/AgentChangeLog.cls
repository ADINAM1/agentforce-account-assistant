/**
 * The Account Assistant change log (Agent_Change_Log__c): one entry per Account
 * field the agent changes, recording who (Created By), what, the old and new
 * values and the user's original request.
 *
 * Revenue changes that need a manager's approval are logged as Pending Approval
 * and submitted to the Revenue_Change_Approval process. The process only sets
 * Status__c; applyApprovalDecisions (called by AgentChangeLogTrigger) makes the
 * approved change in the same transaction, so an entry is only ever Applied if
 * the Account really changed.
 *
 * Approved changes are applied without sharing and in SYSTEM_MODE on purpose:
 * they are made on the authority of the manager's approval, not the approver's
 * own access to the Account.
 */
public without sharing class AgentChangeLog {

    public static final String STATUS_APPLIED = 'Applied';
    public static final String STATUS_PENDING = 'Pending Approval';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String APPROVAL_PROCESS = 'Revenue_Change_Approval';

    /** A new, not yet inserted, Applied entry for one field change. */
    public static Agent_Change_Log__c entry(Account acc, Schema.SObjectField field, Object newValue, String request) {
        return new Agent_Change_Log__c(
            Account__c = acc.Id,
            Field__c = field.getDescribe().getName(),
            Old_Value__c = text(acc.get(field)),
            New_Value__c = text(newValue),
            Original_Request__c = request == null ? null : request.abbreviate(32768),
            Status__c = STATUS_APPLIED);
    }

    /** e.g. "Rating: Warm → Hot; Annual Revenue: 25000000 → 30000000" */
    public static String describe(List<Agent_Change_Log__c> entries) {
        List<String> changes = new List<String>();
        for (Agent_Change_Log__c entry : entries) {
            changes.add(accountField(entry.Field__c).getDescribe().getLabel() + ': '
                + (entry.Old_Value__c == null ? 'blank' : entry.Old_Value__c) + ' → ' + entry.New_Value__c);
        }
        return String.join(changes, '; ');
    }

    /**
     * Before-update handler for decisions from the Revenue Change Approval
     * process: records who reviewed the change and, if approved, makes it.
     */
    public static void applyApprovalDecisions(List<Agent_Change_Log__c> entries, Map<Id, Agent_Change_Log__c> oldEntries) {
        Map<Id, Account> accountUpdates = new Map<Id, Account>();
        Map<Id, List<Agent_Change_Log__c>> approvedByAccount = new Map<Id, List<Agent_Change_Log__c>>();
        for (Agent_Change_Log__c entry : entries) {
            Boolean decided = oldEntries.get(entry.Id).Status__c == STATUS_PENDING
                && (entry.Status__c == STATUS_APPLIED || entry.Status__c == STATUS_REJECTED);
            if (!decided) {
                continue;
            }
            entry.Reviewed_By__c = UserInfo.getUserId();
            if (entry.Status__c == STATUS_REJECTED) {
                continue;
            }
            if (entry.Account__c == null) {
                entry.addError('The account for this change no longer exists.');
                continue;
            }
            if (!accountUpdates.containsKey(entry.Account__c)) {
                accountUpdates.put(entry.Account__c, new Account(Id = entry.Account__c));
                approvedByAccount.put(entry.Account__c, new List<Agent_Change_Log__c>());
            }
            Schema.SObjectField field = accountField(entry.Field__c);
            accountUpdates.get(entry.Account__c).put(field, value(field, entry.New_Value__c));
            approvedByAccount.get(entry.Account__c).add(entry);
        }
        if (accountUpdates.isEmpty()) {
            return;
        }

        List<Account> accounts = accountUpdates.values();
        List<Database.SaveResult> results = Database.update(accounts, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            for (Agent_Change_Log__c entry : approvedByAccount.get(accounts[i].Id)) {
                entry.addError('The approved change could not be applied: ' + results[i].getErrors()[0].getMessage());
            }
        }
    }

    private static Schema.SObjectField accountField(String fieldName) {
        return Account.SObjectType.getDescribe().fields.getMap().get(fieldName);
    }

    /** Converts a logged value back to the field's type. */
    private static Object value(Schema.SObjectField field, String text) {
        if (String.isBlank(text)) {
            return null;
        }
        return field.getDescribe().getSoapType() == Schema.SoapType.DOUBLE ? (Object) Decimal.valueOf(text) : text;
    }

    private static String text(Object value) {
        if (value == null) {
            return null;
        }
        return value instanceof Decimal ? ((Decimal) value).toPlainString() : String.valueOf(value);
    }
}
