# Scenario: Calculator multiplies two digits
Target: x11-command

## Steps
1. Start the application and take a screenshot -- PASS if a calculator with a numeric keypad is visible.
2. Press 7, then the multiply key, then 6, then the equals key, and take a screenshot -- PASS if the display shows 42.
3. Press the clear key (AC or C) -- PASS if the display shows 0.

## Log patterns
- errors: (Error|Warning|cannot)

## Safety
Desktop application under Xvfb: every control is safe to press.
