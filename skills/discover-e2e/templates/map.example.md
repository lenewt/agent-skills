# Product map: <profile name>

Verified facts about the product as a person at the screen sees it. Scouts read this first and propose additions;
the author accepts them with `discover-e2e --accept-map`. Coordinates are native screen pixels.

## Safety
Free text copied into every scout task. One `rect: x1 y1 x2 y2` per screen area nobody may tap.

## Screens
- Start screen: what it shows once the app is up; its main controls and their positions.

## Flows
- <flow name>: the taps that reach it, auto-advancing screens, inactivity timeouts.

## Fixtures and actions
- <state>: the SQL or action line that produces it, and what it changes on screen.

## Logs
- <event>: the log file and a regex that matched it.

## Pitfalls
- Things that cost a scout or a tester a retry.
