# PhoneZero — agent bootstrap

PhoneZero is a Grok Bot skill that books a restaurant table by phone (Telnyx hosted MCP + xAI Voice Agent) with zero user infrastructure.

If asked to set up or use PhoneZero:

1. Read `skills/phonezero/SKILL.md` in full and follow it.
2. If PhoneZero is not yet configured, run that file's **Setup** section first. `docs/SETUP.md` is the human-readable mirror; `scripts/provision.sh` is the developer mirror.
3. `README.md` has the adoption order (keys first, then provision, then remaining ids).
4. Never place a call without the skill's plan-first confirmation and safety rules (US-only, hours guard, two attempts, fail-closed on vague tasks, `booked` only with a host confirmation in the transcript).
5. Never commit or echo keys. `TELNYX_API_KEY` is a plugin variable (backend-held). `XAI_API_KEY` is the secure-secret flow (runtime STT + setup phone-numbers API).
6. The Builder prompt is static. Brief each call by voice in TeXML `<Say>` — do not edit the Builder console per call.
