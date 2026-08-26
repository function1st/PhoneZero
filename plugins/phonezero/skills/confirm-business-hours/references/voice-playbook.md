# Confirm-hours voice playbook (chat agent)

- **goal:** Get a live person to state opening hours (and whether they differ today, if asked).
- **opener:** I'm calling to confirm your opening hours{optional focus}.
- **constraints:** Do not invent hours. Accept only hours a live person states.
- **success:** They state the hours; you read them back; they confirm.
- **voicemail:** {spoken_name} calling to confirm {business} hours. Please call {callback}.
- **playbook:** Ask for hours; ask the optional focus; read back; do not guess.
