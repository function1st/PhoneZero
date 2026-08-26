# Book-restaurant voice playbook (chat agent)

Copy the short versions into `phonezero-task.json`. Do not paste this whole file into the collection.

- **goal:** Book the table within the window.
- **opener:** I'd like to make a reservation for a party of {n} on {date} at {preferred_time}. Do you have availability?
- **constraints:** Preferred time, then ranked alternates, then a host offer inside {window}. Never invent a time.
- **success:** Live host confirms read-back of party, date, agreed time, and booking name.
- **voicemail:** {spoken_name} calling for {booking_name} about a reservation for {n} on {date} at {preferred_time}. Please call {callback}.
- **playbook:** Ask preferred first; then alternates; then in-window host offers. Special requests only after a time is under discussion.
