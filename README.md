# RobotBroadcastDemo

HarmonyOS NEXT / ArkTS robot vacuum broadcast and find-person demo.

## UX V2

- Fixed text instructions and press-to-record voice broadcast (30 s maximum)
- Review, replay, re-record, and send recorded audio
- Local network transfer adapter and WebSocket task-status adapter
- Continuous task stages: connecting → accepted → speaking → searching → found
- Success, failure, disconnect, and retry flows

## Important

The current V2 demo uses simulated LAN transfer and simulated status events. It does not perform actual WebSocket communication with a vacuum or detect a real person. Real device integration requires the protocol, authentication, endpoint, and status event schema.
