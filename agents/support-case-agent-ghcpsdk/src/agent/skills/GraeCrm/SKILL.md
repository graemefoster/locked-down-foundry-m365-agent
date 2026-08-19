---
name: GraeCrm
description: |
  Diagnose problems starting or accessing GraeCRM, the company CRM application.
  Use whenever a user reports that GraeCRM will not start, will not open, shows an
  access-denied or permission error, or that they cannot access GraeCRM.
  Triggers: "GraeCRM won't start", "can't open GraeCRM", "GraeCRM access denied",
  "GraeCRM permission error", "I can't access GraeCRM".
---

# GraeCRM Access Triage

GraeCRM is a fictitious CRM application in this proof-of-concept. This skill covers the
supported first-line triage for a user who cannot start or access GraeCRM. Do not invent
alternative URLs, roles, policies, support teams, or remediation steps.

The expected root cause is a **permission (access) issue**: the signed-in account is missing
the role required to use GraeCRM. Your job in this skill is to confirm that GraeCRM will not
start, rule out obvious non-access causes, and — once you conclude it is an access problem —
hand off to the **GraeIdentity** skill to take the user through the identity-management process.

## 1. Establish the symptom

Confirm that the user cannot start or access GraeCRM. Ask for the exact error text if they have
it. Acknowledge the error without diagnosing beyond the visible evidence.

Common signs that this is a **permission issue** (and therefore a GraeIdentity matter):

- An access-denied, "not authorized", "you do not have permission", or "missing role" message.
- GraeCRM opens to a sign-in or authorization screen and then refuses to load the app.
- The app starts but reports the account lacks the required GraeCRM role.

If the reported problem is clearly **not** an access issue — for example the site is completely
down for everyone, a network or DNS error, or a browser/rendering fault — say that this skill
only covers GraeCRM access triage and that the issue looks like something else. Do not fabricate
a fix.

## 2. Confirm it is an access problem

Explain to the user that the first-line check for GraeCRM start-up failures is whether their
signed-in account holds the role required to use GraeCRM. Most GraeCRM "won't start" reports in
this environment are caused by the account missing that role.

Ask the user to confirm the account they are signed in with when GraeCRM fails, and to describe
(or screenshot) the exact failure. If the evidence points to an authorization or missing-role
failure, treat this as an access/permission problem.

## 3. Hand off to identity management

Once you have concluded this is an access/permission issue, hand off to the **GraeIdentity**
skill, which owns the identity-management process: verifying the account, checking the assigned
role, requesting the required GraeCRM access role, and interpreting the approval result.

Carry forward the evidence you have already gathered — the signed-in account identifier and the
exact GraeCRM error — so the user does not have to repeat completed steps. Do not attempt to
guide the role-request process from this skill; follow the GraeIdentity skill for those steps.

## 4. Confirm resolution

The case is resolved only when the user confirms GraeCRM now starts successfully after the
access issue has been addressed via GraeIdentity. If the required access is verified as active
but GraeCRM still will not start, summarise the evidence collected (the account identifier, the
confirmed active GraeCRM role, and the exact GraeCRM error) and use the **EscalationSkill** to
raise an escalation to application support, giving the user the ticket reference it returns. Do
not invent further technical fixes.
