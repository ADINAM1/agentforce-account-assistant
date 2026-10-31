/**
 * Shared validation for values the agent's LLM passes into Account actions.
 * Free text from a model is never trusted: Ids must really be Account Ids and
 * picklist values must exist in the org's schema.
 */
public inherited sharing class AgentInputValidation {

    public class InvalidValueException extends Exception {}

    /** Returns the value as an Account Id, or null if it is blank or not an Account Id. */
    public static Id accountId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            Id recordId = Id.valueOf(value.trim());
            return recordId.getSObjectType() == Account.SObjectType ? recordId : null;
        } catch (StringException e) {
            return null;
        }
    }

    /** Returns the org's canonical picklist value (matching case-insensitively) or throws. */
    public static String picklistValue(Schema.SObjectField field, String input) {
        List<String> allowed = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            if (entry.getValue().equalsIgnoreCase(input.trim())) {
                return entry.getValue();
            }
            allowed.add(entry.getValue());
        }
        throw new InvalidValueException('"' + input + '" is not a valid ' + field.getDescribe().getLabel()
            + '. Allowed values: ' + String.join(allowed, ', ') + '.');
    }
}
