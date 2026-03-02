Component Overview
Name: Enhanced Path (EnhancedPath) Purpose: A custom, visually distinct, and responsive progress indicator (Path) specifically designed for Salesforce Screen Flows. It replaces the standard arrow-based path with an equal-width, pill-shaped card layout that supports dynamic states and custom iconography.

1. Configurable Inputs (Flow Builder Attributes)
The component must expose the following configuration properties to Flow Admins:
Current Step Name (currentStep): A text string representing the exact name of the currently active step.
Steps (stepsCsv): A comma-separated list of all step names in sequential order (e.g., Draft,Review,Approved,Closed).
Icons (iconsCsv): A comma-separated list defining an icon for each step.
Supports standard SLDS icons (e.g., utility:user).
Supports custom images via Static Resources.
Allows skipping icons using the keyword NULL or leaving it empty.
Mark Last Step as Complete (isLastStepComplete): A boolean toggle (default: false). If true, when the flow reaches the final step, it will display as "Complete" (green checkmark) rather than "Current" (blue outline).
Component Size (componentSize): A dropdown/text input to select the display size: Small, Medium (default), or Large.
2. Business & State Logic
The component must dynamically calculate the state of each step by comparing it against the currentStep:
Completed State (Past Steps): Any step appearing before the currentStep in the CSV list.
UI: Shows a green outline, green text, and a standard SLDS success checkmark (utility:check). Custom icons are overridden by the checkmark.
Current State (Active Step): The step that exactly matches the currentStep.
UI: Shows a prominent blue, thicker border (#0176d3), bold blue text, and a subtle blue inner shadow. Displays its assigned custom icon or SLDS icon.
Incomplete State (Future Steps): Any step appearing after the currentStep.
UI: Shows a gray outline (#c9c7c5), gray text, and grayed-out icons.
3. UI/UX & Styling Requirements
Layout: Steps must be forced into equal widths using a Flexbox layout (flex: 1 1 0px), filling 100% of the container width.
Shape: The standard Salesforce path arrows must be completely hidden. Steps must be rendered as rounded pills (border-radius: 2rem) with a centered layout (Checkmark/Icon + Text).
Responsiveness: The component must adjust padding, font size, and icon size based on the selected componentSize (Small, Medium, Large).
Interaction: The path is purely visual/read-only. User click interactions must be disabled (pointer-events: none).
Text Handling: Long step names must not break the layout; they must use a single line with an ellipsis (text-overflow: ellipsis) if they overflow.
4. Technical & Metadata Requirements
Target: The LWC must be strictly exposed to lightning__FlowScreen.
API Version: 66.0 (Spring '26).
Resource Handling: If a custom icon string does not include a colon (meaning it's not an SLDS icon) and doesn't start with an HTTP/slash path, the component must automatically prefix it with /resource/ to correctly route to Salesforce Static Resources.

