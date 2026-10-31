# Agentforce Account Assistant

An Agentforce **employee agent** (`Account_Assistant_Employee`) that lets sales reps update Salesforce Account records through conversation, e.g. *"Change Initech's rating to Warm"*. Built with the new Agentforce Builder and **Agent Script**, managed as source with the Salesforce CLI.

## How it works

```
User message
  └─▶ Agent Router (start agent)
        ├─▶ Account Management subagent ──▶ Update Account Fields action ──▶ UpdateAccountAction (Apex, USER_MODE)
        ├─▶ Off Topic
        ├─▶ Ambiguous Question
        └─▶ Escalation (hand-off to human)
```

| Component | Path |
|---|---|
| Agent definition (Agent Script) | `force-app/main/default/aiAuthoringBundles/Account_Assistant_1/Account_Assistant_1.agent` |
| Apex invocable action | `force-app/main/default/classes/UpdateAccountAction.cls` |
| Apex unit tests (6) | `force-app/main/default/classes/UpdateAccountActionTest.cls` |
| Agent user permission set | `force-app/main/default/permissionsets/Account_Assistant_Agent_Access.permissionset-meta.xml` |
| Agent test spec (5 cases) | `specs/Account_Assistant-testSpec.yaml` |
| Agent test metadata | `force-app/main/default/aiEvaluationDefinitions/` |

## Design decisions

- **Platform-enforced confirmation** – the action sets `require_user_confirmation: True`, so the platform (not the LLM) asks the user before any update runs.
- **Least privilege** – the agent runs as its own user. A dedicated permission set grants only the Apex class plus Read/Edit on Account and the four fields it changes; no create, delete or view-all.
- **USER_MODE Apex** – queries and DML enforce the running user's object, field and sharing access.
- **Deterministic validation** – picklist values are checked against the org schema (`hot` → `Hot`, `Super Hot` → rejected with allowed values); ambiguous names return the candidate list instead of guessing.
- **Descriptions as prompts** – action and input descriptions are written for the reasoning engine, since they drive when the action is chosen and how inputs are filled.
- **Auditability** – changes show the agent user in *Last Modified By*.

## Deploy

```bash
sf org login web --alias agentforce-dev --set-default
sf project deploy start --source-dir force-app --test-level RunSpecifiedTests --tests UpdateAccountActionTest
sf org assign permset --name Account_Assistant_Agent_Access --on-behalf-of <agent-user-username>
```

Then open the agent in Agentforce Builder, **Commit Version** and **Activate**. Note: `access.default_agent_user` in the `.agent` file is org-specific; update it for a new org.

## Test

```bash
# Apex unit tests
sf apex run test --tests UpdateAccountActionTest --wait 10

# Agent tests: routing, actions and LLM-graded outcomes
sf agent test run --api-name Account_Assistant_Tests --wait 15 --result-format human
```

Latest run: topic 100%, action 100%, outcome 100%.

## Lessons learned

- Orgs with State/Country picklists reject free-text `BillingCountry` on import; load `BillingCountryCode` / `BillingStateCode` instead.
- A new agent user has no permissions: a silent blank response in Preview was a missing Apex class / Account permission.
- Asking for confirmation in instructions *and* via `require_user_confirmation` double-prompts; keep the platform guardrail and drop the instruction.
- Escalation via `@utils.escalate` is reported as topic `human` in agent test results.
- The Builder's default "New Agent" flow created a **service agent** (`EinsteinServiceAgent`, customer-facing, own agent user, messaging variables), which never appears in the Lightning Agentforce panel. Agent type can't be changed in place, so the employee version was published from a copy of the script with `agent_type: "AgentforceEmployeeAgent"`, no dedicated agent user (employee agents run as the logged-in user) and no live-agent escalation. `Account_Assistant_1` is kept as the service-agent variant.
- Two separate permission layers: what the agent can do (`Account_Assistant_Agent_Access`, service-agent user) vs. who can talk to it (`Account_Assistant_User`, Agent Access).
