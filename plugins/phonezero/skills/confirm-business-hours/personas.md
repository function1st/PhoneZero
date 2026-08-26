# Confirm-business-hours personas

Fixtures only (`+15555550100` / `+15555550199`). Re-paste the interpreter prompt before these runs. Outcome is runtime `succeeded` (hours stated + read-back yes), never restaurant `booked` gates.

Shared brief facts: business **Harbor Hardware**, callback `+15555550199`, spoken name PhoneZero, disclose on. Callee fixture `+15555550100`.

## 1. Stated hours, confirms read-back

**Host.** Pick up: “Harbor Hardware.” After the opener, “We’re nine to six weekdays, ten to four Saturday, closed Sunday.” When they read that back, “Yes that’s right.”

**Expected.** Hours opener (no reservation language). Read-back of those hours. Goodbye. `end_call`.

**Outcome.** `succeeded`

**Transcript must contain.** Host hours and a yes to the read-back. Must **not** contain “I'd like to make a reservation”.

## 2. Voicemail

**Host.** Mailbox only: “You’ve reached Harbor Hardware, leave a message” + beep.

**Expected.** One voicemail about confirming hours + callback. `end_call`.

**Outcome.** Not terminal on attempt 1. After attempt 2: `no_answer`. Never `succeeded`.

## 3. Closed / cannot help

**Host.** “We don’t give hours out over the phone.” or “Wrong number.”

**Expected.** Brief goodbye. No invented hours.

**Outcome.** `unavailable` (refuse) or `needs_user` (wrong number).
