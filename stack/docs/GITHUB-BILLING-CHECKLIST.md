# GitHub billing checklist — get the lock off the account

The account `MartinMayday` is **billing-locked**. GitHub's own annotation
says it plainly:

> "The job was not started because your account is locked due to a billing issue."

This happens when GitHub tries to charge a payment method and the charge
fails. Public repositories are included — a lock on the account stops
GitHub-hosted jobs everywhere.

This checklist is in order. Do not skip ahead; each step depends on the one
before it.

---

## Step 1 — confirm the lock is still on

```bash
gh auth refresh -h github.com -s user
/opt/oma-stack/stack/verify/billing-check.sh
```

Look for:

```
app=github-actions  status=completed  conclusion=startup_failure
```

If you see `success` anywhere on the newest commit, the lock is already gone
and this checklist is not needed.

---

## Step 2 — add the card

1. Open https://github.com/settings/billing
2. Under **Payment method**, click **Add payment method**.
3. Enter the card number, expiry, CVC, and the **exact billing address** as
   the card issuer has it. A mismatch here is the single most common cause of
   a lock that survives a "valid" card.
4. Click **Add**.

GitHub may ask you to authorise a $0 or small charge. Some issuers block
pre-authorisations from unfamiliar merchants — approve it at the bank if the
card was declined.

---

## Step 3 — clear any failed invoice or hold

https://github.com/settings/billing → **Payment history** / **Invoices**

- Any invoice marked **Failed** or **Past due** must be paid.
- A failed authorisation hold is enough to keep the account locked even when
  the card itself is fine. Retrying the payment after the bank releases the
  hold clears it.

If you see "Your account is locked pending payment", paying the outstanding
invoice is the fix.

---

## Step 4 — check the spending limit and budgets

This one bites silently: a valid card with a zero spending limit still
produces `startup_failure`.

1. https://github.com/settings/billing → **Spending limit**
   - Set it to a real number. $0 means "never spend".
2. https://github.com/settings/billing → **Budgets and alerts**
   - For each budget, check **Stop usage when the budget is reached**. If
     that is on and the budget is exhausted, jobs stop starting.
   - Set a hard stop of "0" or a comfortable monthly figure.

Budgets are per-repository and per-organisation as well as account-wide. Check
the org settings too if you use any.

---

## Step 5 — confirm the fix

```bash
gh auth refresh -h github.com -s user
/opt/oma-stack/stack/verify/billing-check.sh
```

Then run a real job. Use a public repo (private repos have their own failure
mode while the lock is on):

```bash
cd /tmp && rm -rf lockcheck && mkdir lockcheck && cd lockcheck
git init -q -b main .
mkdir -p .github/workflows
cat >.github/workflows/lockcheck.yml <<'YML'
name: lockcheck
on: [push]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo LOCK_IS_GONE
YML
git add -A && git commit -q -m "chore: lock check"
git remote add origin https://github.com/MartinMayday/agents-md-generator.git
git push -q origin main

gh run list --repo MartinMayday/agents-md-generator --limit 1
```

A `success` conclusion means the lock is off. A `failure` conclusion with the
billing annotation means it is still on — go back to step 2.

---

## Step 6 — what about the free tier?

For context, because this comes up:

- GitHub-hosted runners for **public repositories** are free and do not draw
  on your included compute.
- **Self-hosted runners are free.** They never consume the included compute,
  which is why the MacBook keeps running public-repo CI even while the account
  is locked.
- The included compute for private repositories is expressed in USD now
  ($12 on Free, $18 on Pro), not in minutes.
- Usage is blocked once the included compute is exhausted **and** there is no
  valid payment method on file. A card on file is therefore required even on
  the free tier for private-repo Actions to keep running.

---

## Step 7 — after the lock clears

Run the closure audit against everything you closed during the outage:

```bash
python3 scripts/verify_closure.py --issue <N> --repo MartinMayday/agent-library
```

The audit requires green CI on the merge commit. Issues closed during the
lock will fail that check until CI runs on their merge commits. Reopen any
that fail, or let the audit comment explain itself.

Also check the branches left over from the outage:

```bash
git ls-remote --heads origin | grep -E 'ci/|probe'
```

and delete the diagnostic branches if any remain.

---

## Privacy note

The card number never touches this machine. You enter it on GitHub's own
billing page over HTTPS, and GitHub stores the tokenised card. The fallback
package deliberately contains no payment handling of any kind — it only reads
GitHub's billing state through the API.
