# Agentforce Account Assistant

An Agentforce **employee agent** (`Account_Assistant_Employee`) that sales reps use from the Lightning Agentforce panel to look up, summarize and update Salesforce Accounts and log follow-ups, e.g. *"Which Hot accounts are in Finance?"*, *"Make this one Hot"* or *"Remind me to call their CFO tomorrow"*. Every change it makes is recorded in a change log, and revenue changes involving more than $100M wait for the user's manager to approve them. Built with the new Agentforce Builder and **Agent Script**, managed as source with the Salesforce CLI.

## How it works

```
User message (+ record on screen: currentRecordId / currentObjectApiName)
  └─▶ Agent Router (start agent)
        ├─▶ Account Management subagent
        │     ├─▶ find_accounts   ──▶ FindAccountsAction (Apex, read-only)
        │     ├─▶ update_account  ──▶ UpdateAccountAction (Apex, platform confirmation)
        │     │                         ├─▶ change applied + Agent_Change_Log__c entry (Applied)
        │     │                         └─▶ revenue change over $100M: entry (Pending Approval)
        │     │                               ──▶ Revenue Change Approval (the user's manager)
        │     │                               ──▶ approved: AgentChangeLogTrigger applies it
        │     └─▶ log_follow_up   ──▶ Log_Account_Follow_Up (Flow, creates a Task)
        ├─▶ Off Topic
        └─▶ Ambiguous Question
```

| What the user says | What happens |
|---|---|
| "Tell me about Stark Energy" | `find_accounts` returns a profile: fields, notes, open opportunities, latest follow-ups and recent changes made through the agent |
| "Which Hot accounts are in Finance?" / "accounts over $50M" | `find_accounts` with filters (rating, industry, type, state, revenue range) returns a list |
| "Set Initech's rating to Hot" | `find_accounts` resolves the name to an Id (asks if several match), then `update_account` shows a confirmation card, makes the change and logs it |
| "Set this account's revenue to 150 million" | After the confirmation card, the change is logged as Pending Approval and sent to the user's manager; it's applied automatically when they approve |
| "What changed on this account? Was my change approved?" | `find_accounts` answers from the change log: field, old and new value, status, who requested it and who reviewed it |
| "Log a follow-up on Acme to send pricing next Friday" | `find_accounts` resolves the Id, then `log_follow_up` creates a Task due on that date |
| "Summarize this account" / "Make this one Hot" (on an Account page) | Uses the page's record Id directly, no name needed |

## Components

| Component | Path |
|---|---|
| Employee agent (Agent Script) | `force-app/main/default/aiAuthoringBundles/Account_Assistant_Employee/` |
| Find Accounts action + 10 tests | `force-app/main/default/classes/FindAccountsAction.cls`, `FindAccountsActionTest.cls` |
| Update Account Fields action + 11 tests | `force-app/main/default/classes/UpdateAccountAction.cls`, `UpdateAccountActionTest.cls` |
| Change log object (one record per field changed), tab, layout, list views | `force-app/main/default/objects/Agent_Change_Log__c/`, `tabs/`, `layouts/` |
| Change log and approval logic, trigger + 8 tests | `force-app/main/default/classes/AgentChangeLog.cls`, `triggers/AgentChangeLogTrigger.trigger`, `classes/AgentChangeLogTest.cls` |
| Revenue Change Approval (manager approval) and its field updates | `force-app/main/default/approvalProcesses/`, `workflows/Agent_Change_Log__c.workflow-meta.xml` |
| Change history on the Account page | `force-app/main/default/layouts/Account-Account Layout.layout-meta.xml` (Agent Change Logs related list) |
| Shared input validation | `force-app/main/default/classes/AgentInputValidation.cls` |
| Log Follow-Up Flow + 4 Apex tests | `force-app/main/default/flows/Log_Account_Follow_Up.flow-meta.xml`, `classes/LogAccountFollowUpFlowTest.cls` |
| End-user permission set | `force-app/main/default/permissionsets/Account_Assistant_User.permissionset-meta.xml` |
| Agent test specs | `specs/Account_Assistant_Employee-testSpec.yaml` (employee), `specs/Account_Assistant-testSpec.yaml` (service variant) |
| Service-agent variant | `aiAuthoringBundles/Account_Assistant_1/` + `Account_Assistant_Agent_Access` permission set |

## Design decisions

- **Resolve, then change.** Writes need an Account Id: from the record on screen, or from `find_accounts` (a read, no confirmation). Ambiguous names are settled *before* a confirmation card appears, and the platform-generated confirmation describes only the change ("set the account rating to Hot") instead of misreading the name as a field being changed.
- **Platform-enforced confirmation.** `update_account` sets `require_user_confirmation: True`, so the platform, not the LLM, gates every update. Logging a Task is low-risk and reversible, so it runs without a confirmation step to avoid confirmation fatigue.
- **An audit log the agent can't skip.** Every change writes an `Agent_Change_Log__c` record in the same transaction as the update, so there is no change without a log entry. Each entry records who (Created By, the real user), the field, the old and new values, the user's original request (an action input the LLM fills from the conversation), the status and the reviewer. Users can read the log but not write to it: only the action creates entries, in explicit `SYSTEM_MODE`, so entries can't be edited, deleted or forged. A lookup rather than master-detail keeps the history if an account is deleted. Field History Tracking records who and before/after, but not that the change came from the agent, what the user asked for, or changes still waiting for approval.
- **Business rules in the action, approvals in the platform.** The $100M rule lives in Apex, not in the prompt or Agent Script, so it holds for every caller: this agent, another agent, a Flow or the API. A revenue update needs approval when the revenue before or after the change is over $100M, which catches big jumps, big cuts and unit slips such as million vs billion. The standard Approval Process routes the change to the requester's Manager. The process only sets the entry's status; a before-update trigger applies the change in the same transaction, so an entry only becomes Applied if the Account really changed. In a mixed request, small changes apply immediately and only the revenue change waits, and there is at most one pending revenue change per account.
- **Two human checks for high-impact changes.** The confirmation card checks that the agent understood the user; the approval checks that the change is allowed. Low-risk changes get one check, big revenue changes get both.
- **Apex vs Flow.** Lookups and updates are Apex (dynamic filters with bind variables, picklist validation, ambiguity handling, unit tests). Logging a follow-up is a Flow, a simple create an admin can own and change without code.
- **Record-page context.** `currentRecordId` / `currentObjectApiName` are `External` variables the Lightning panel fills in; a deterministic `if` in the instructions tells the LLM which record "this account" means only when the user is on an Account.
- **Never trust model input.** Ids must really be Account Ids and picklist values must exist in the schema (`hot` → `Hot`, `Super Hot` → rejected with the allowed values). Values that wouldn't change anything are skipped rather than logged.
- **Runs as the user.** Employee agents use the signed-in user's access; Apex runs in `USER_MODE` and the Flow in default (user) context, so the agent can never see or change more than the user could. The only exceptions are explicit and commented: writing the change log, and applying a change the manager approved.
- **Cost awareness.** Agentforce bills per action, so instructions avoid unnecessary calls; the one extra lookup before a named update is a deliberate trade for correct disambiguation and confirmation.
- **Descriptions as prompts.** Action and input descriptions/labels are written for the reasoning engine and for the confirmation card the user sees.

## Deploy

The order matters: the Apex tests need the change log object to exist already, and the permission set references the agent.

```bash
sf org login web --alias agentforce-dev --set-default
# 1. Change log object, approval process, layouts and tab (no Apex, so no tests run)
sf project deploy start --source-dir force-app/main/default/objects --source-dir force-app/main/default/workflows \
  --source-dir force-app/main/default/approvalProcesses --source-dir force-app/main/default/layouts \
  --source-dir force-app/main/default/tabs
# 2. Apex, trigger and Flow, with tests
sf project deploy start --source-dir force-app/main/default/classes --source-dir force-app/main/default/triggers \
  --source-dir force-app/main/default/flows --test-level RunSpecifiedTests --tests UpdateAccountActionTest \
  --tests FindAccountsActionTest --tests LogAccountFollowUpFlowTest --tests AgentChangeLogTest
# 3. Agent
sf agent publish authoring-bundle --api-name Account_Assistant_Employee
sf agent activate --api-name Account_Assistant_Employee --version <new version>
# 4. Access for employees and their managers (managers need to read the change log to approve)
sf project deploy start --metadata PermissionSet:Account_Assistant_User
sf org assign permset --name Account_Assistant_User --on-behalf-of <employee username> --on-behalf-of <manager username>
```

Revenue approvals go to each user's **Manager** field, so every employee who uses the agent needs a manager set. The dev org has a demo manager user, Jordan Lee, set as the employee user's manager. For demos where you can't log in as the manager, `sf apex run --file scripts/apex/approve-pending-revenue-change.apex` approves the newest pending revenue change as an admin.

## Test

Three layers, because no single one can check everything:

```bash
# 1. Apex unit tests (33): actions, validation, change log, approval routing/approve/reject, and the Flow via Flow.Interview
sf apex run test --tests UpdateAccountActionTest --tests FindAccountsActionTest --tests LogAccountFollowUpFlowTest \
  --tests AgentChangeLogTest --wait 10

# 2. Agent tests: routing, actions and LLM-graded outcomes, incl. record-page context (7 cases)
sf agent test run --api-name Account_Assistant_Employee_Tests --wait 20 --result-format human

# 3. Scripted preview for multi-turn, confirmation and approval behaviour batch tests can't capture
sf agent preview start --api-name Account_Assistant_Employee --context-variables currentObjectApiName=Account --context-variables currentRecordId=<Account Id>
sf agent preview send --session-id <id> --api-name Account_Assistant_Employee --utterance "Set its annual revenue to 150 million"
sf agent preview send --session-id <id> --api-name Account_Assistant_Employee --utterance "Yes, confirm"
```

Latest runs: Apex 33/33; agent tests topic 7/7, action 7/7, outcome 7/7. The scripted preview checked a rating change (applied and logged with the user's words), a $67M → $150M revenue change (sent to Jordan Lee, applied by the trigger once approved) and a change-history question answered from the log. The agent tests use the sample accounts loaded into the dev org (the record-context case references Wayne Retail Group's Id), and the follow-up case creates a Task each run.

## Lessons learned

- Orgs with State/Country picklists reject free-text `BillingCountry` on import; load `BillingCountryCode` / `BillingStateCode` instead.
- The Builder's default "New Agent" flow created a **service agent** (customer-facing, own agent user, messaging variables), which never appears in the Lightning panel. Agent type can't be changed in place, so the employee agent was published from a copy of the script with `agent_type: "AgentforceEmployeeAgent"`, no `default_agent_user` and no `@utils.escalate`.
- Two permission layers: what a service agent's own user can do (`Account_Assistant_Agent_Access`) vs. who can talk to the employee agent and run its actions (`Account_Assistant_User`).
- A new service-agent user has no permissions: a silent blank response in Preview was a missing Apex class / Account permission.
- Asking for confirmation in instructions *and* via `require_user_confirmation` double-prompts; keep the platform guardrail.
- The confirmation sentence is generated by the platform from the action's inputs, not from instructions or labels: a name input was described as "change the account name". Passing an Id instead fixed it. Adding the `originalRequest` input didn't confuse it: the card lists the request, and the sentence still describes only the change.
- In an employee agent the confirmation is a UI card, which batch agent tests can't capture; test updates with Apex tests and scripted preview instead.
- `sf agent publish` retrieves metadata back into the project and can strip trailing newlines from Apex files; review `git diff` after publishing.
- **Apex at API 67.0+ runs SOQL and DML in user mode by default.** A plain `insert` of a log entry failed with "DML operation INSERT not allowed" for users who can only read the log. Writes that intentionally go beyond the user's own permissions (the audit log, applying an approved change) now say `AccessLevel.SYSTEM_MODE` explicitly.
- Deploying a new object together with Apex tests that use it as non-admin users failed with "sObject type 'Agent_Change_Log__c' is not supported"; the object has to be deployed first.
