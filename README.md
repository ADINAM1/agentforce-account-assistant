# Agentforce Account Assistant

An Agentforce **employee agent** (`Account_Assistant_Employee`) that sales reps use from the Lightning Agentforce panel to look up, summarize and update Salesforce Accounts and log follow-ups, e.g. *"Which Hot accounts are in Finance?"*, *"Make this one Hot"* or *"Remind me to call their CFO tomorrow"*. Built with the new Agentforce Builder and **Agent Script**, managed as source with the Salesforce CLI.

## How it works

```
User message (+ record on screen: currentRecordId / currentObjectApiName)
  └─▶ Agent Router (start agent)
        ├─▶ Account Management subagent
        │     ├─▶ find_accounts   ──▶ FindAccountsAction (Apex, read-only)
        │     ├─▶ update_account  ──▶ UpdateAccountAction (Apex, platform confirmation)
        │     └─▶ log_follow_up   ──▶ Log_Account_Follow_Up (Flow, creates a Task)
        ├─▶ Off Topic
        └─▶ Ambiguous Question
```

| What the user says | What happens |
|---|---|
| "Tell me about Stark Energy" | `find_accounts` returns a profile: fields, notes, open opportunities, latest follow-ups |
| "Which Hot accounts are in Finance?" / "accounts over $50M" | `find_accounts` with filters (rating, industry, type, state, revenue range) returns a list |
| "Set Initech's rating to Hot" | `find_accounts` resolves the name to an Id (asks if several match), then `update_account` shows a confirmation card |
| "Log a follow-up on Acme to send pricing next Friday" | `find_accounts` resolves the Id, then `log_follow_up` creates a Task due on that date |
| "Summarize this account" / "Make this one Hot" (on an Account page) | Uses the page's record Id directly, no name needed |

## Components

| Component | Path |
|---|---|
| Employee agent (Agent Script) | `force-app/main/default/aiAuthoringBundles/Account_Assistant_Employee/` |
| Find Accounts action + 9 tests | `force-app/main/default/classes/FindAccountsAction.cls`, `FindAccountsActionTest.cls` |
| Update Account Fields action + 11 tests | `force-app/main/default/classes/UpdateAccountAction.cls`, `UpdateAccountActionTest.cls` |
| Shared input validation | `force-app/main/default/classes/AgentInputValidation.cls` |
| Log Follow-Up Flow + 4 Apex tests | `force-app/main/default/flows/Log_Account_Follow_Up.flow-meta.xml`, `classes/LogAccountFollowUpFlowTest.cls` |
| End-user permission set | `force-app/main/default/permissionsets/Account_Assistant_User.permissionset-meta.xml` |
| Agent test specs | `specs/Account_Assistant_Employee-testSpec.yaml` (employee), `specs/Account_Assistant-testSpec.yaml` (service variant) |
| Service-agent variant | `aiAuthoringBundles/Account_Assistant_1/` + `Account_Assistant_Agent_Access` permission set |

## Design decisions

- **Resolve, then change.** Writes need an Account Id: from the record on screen, or from `find_accounts` (a read, no confirmation). Ambiguous names are settled *before* a confirmation card appears, and the platform-generated confirmation describes only the change ("set the account rating to Hot") instead of misreading the name as a field being changed.
- **Platform-enforced confirmation.** `update_account` sets `require_user_confirmation: True`, so the platform, not the LLM, gates every update. Logging a Task is low-risk and reversible, so it runs without a confirmation step to avoid confirmation fatigue.
- **Apex vs Flow.** Lookups and updates are Apex (dynamic filters with bind variables, picklist validation, ambiguity handling, unit tests). Logging a follow-up is a Flow, a simple create an admin can own and change without code.
- **Record-page context.** `currentRecordId` / `currentObjectApiName` are `External` variables the Lightning panel fills in; a deterministic `if` in the instructions tells the LLM which record "this account" means only when the user is on an Account.
- **Never trust model input.** Ids must really be Account Ids and picklist values must exist in the schema (`hot` → `Hot`, `Super Hot` → rejected with the allowed values).
- **Runs as the user.** Employee agents use the signed-in user's access; Apex runs in `USER_MODE` and the Flow in default (user) context, so the agent can never see or change more than the user could. Changes and Tasks show the real user in the audit fields.
- **Cost awareness.** Agentforce bills per action, so instructions avoid unnecessary calls; the one extra lookup before a named update is a deliberate trade for correct disambiguation and confirmation.
- **Descriptions as prompts.** Action and input descriptions/labels are written for the reasoning engine and for the confirmation card the user sees.

## Deploy

```bash
sf org login web --alias agentforce-dev --set-default
sf project deploy start --source-dir force-app/main/default/classes --source-dir force-app/main/default/flows \
  --test-level RunSpecifiedTests --tests UpdateAccountActionTest --tests FindAccountsActionTest --tests LogAccountFollowUpFlowTest
sf agent publish authoring-bundle --api-name Account_Assistant_Employee
sf agent activate --api-name Account_Assistant_Employee --version <new version>
sf project deploy start --metadata PermissionSet:Account_Assistant_User
sf org assign permset --name Account_Assistant_User --on-behalf-of <employee username>
```

## Test

Three layers, because no single one can check everything:

```bash
# 1. Apex unit tests (24): actions, validation, and the Flow via Flow.Interview
sf apex run test --tests UpdateAccountActionTest --tests FindAccountsActionTest --tests LogAccountFollowUpFlowTest --wait 10

# 2. Agent tests: routing, actions and LLM-graded outcomes, incl. record-page context (7 cases)
sf agent test run --api-name Account_Assistant_Employee_Tests --wait 20 --result-format human

# 3. Scripted preview for multi-turn and confirmation behaviour batch tests can't capture
sf agent preview start --api-name Account_Assistant_Employee --context-variables currentObjectApiName=Account --context-variables currentRecordId=<Account Id>
sf agent preview send --session-id <id> --api-name Account_Assistant_Employee --utterance "Make this one Hot"
```

Latest runs: Apex 24/24; agent tests topic 7/7, action 7/7, outcome 7/7. The agent tests use the sample accounts loaded into the dev org (the record-context case references Wayne Retail Group's Id), and the follow-up case creates a Task each run.

## Lessons learned

- Orgs with State/Country picklists reject free-text `BillingCountry` on import; load `BillingCountryCode` / `BillingStateCode` instead.
- The Builder's default "New Agent" flow created a **service agent** (customer-facing, own agent user, messaging variables), which never appears in the Lightning panel. Agent type can't be changed in place, so the employee agent was published from a copy of the script with `agent_type: "AgentforceEmployeeAgent"`, no `default_agent_user` and no `@utils.escalate`.
- Two permission layers: what a service agent's own user can do (`Account_Assistant_Agent_Access`) vs. who can talk to the employee agent and run its actions (`Account_Assistant_User`).
- A new service-agent user has no permissions: a silent blank response in Preview was a missing Apex class / Account permission.
- Asking for confirmation in instructions *and* via `require_user_confirmation` double-prompts; keep the platform guardrail.
- The confirmation sentence is generated by the platform from the action's inputs, not from instructions or labels: a name input was described as "change the account name". Passing an Id instead fixed it.
- In an employee agent the confirmation is a UI card, which batch agent tests can't capture; test updates with Apex tests and scripted preview instead.
- `sf agent publish` retrieves metadata back into the project and can strip trailing newlines from Apex files; review `git diff` after publishing.
