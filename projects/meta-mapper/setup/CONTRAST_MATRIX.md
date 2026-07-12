# MetaMapper Node Color Contrast Matrix
## Required before any LWC implementation (per CLAUDE.md)

### Calculation Method
WCAG 2.1 relative luminance formula:
- For each 8-bit channel c (0-255): c_sRGB = c / 255
- If c_sRGB <= 0.03928: c_lin = c_sRGB / 12.92; else c_lin = ((c_sRGB + 0.055) / 1.055) ^ 2.4
- L = 0.2126 * R_lin + 0.7152 * G_lin + 0.0722 * B_lin
- Contrast ratio = (L_lighter + 0.05) / (L_darker + 0.05)

Background luminances:
- **#FFFFFF** (light): L = 1.0
- **#1B1B1B** (SLDS dark): L ≈ 0.0114

---

## Node Color Contrast Matrix

| Metadata Type | SLDS Token | Hex | Luminance | Contrast on #FFFFFF | WCAG AA Normal (≥4.5:1) | WCAG AA Large/UI (≥3:1) | Contrast on #1B1B1B | WCAG AA Normal (≥4.5:1) | WCAG AA Large/UI (≥3:1) |
|---|---|---|---|---|---|---|---|---|---|
| ApexClass | --lwc-colorTextActionLabelActive | #0176d3 | 0.1766 | 4.63:1 | PASS | PASS | 3.69:1 | FAIL | PASS |
| ApexTrigger | --lwc-colorTextActionLabelActive | #0176d3 | 0.1766 | 4.63:1 | PASS | PASS | 3.69:1 | FAIL | PASS |
| Flow | --lwc-brandAccessibilityColor | #1b5297 | 0.0850 | 7.78:1 | PASS | PASS | 2.20:1 | FAIL | FAIL |
| CustomField | --lwc-colorTextSuccess | #2e844a | 0.1752 | 4.66:1 | PASS | PASS | 3.67:1 | FAIL | PASS |
| ValidationRule | --lwc-colorTextError | #ba0517 | 0.1059 | 6.73:1 | PASS | PASS | 2.54:1 | FAIL | FAIL |
| WorkflowRule | --lwc-colorTextWarning | #dd7a01 | 0.2930 | 3.06:1 | FAIL | PASS | 5.59:1 | PASS | PASS |
| Report | --lwc-colorTextInverse | #444444 | 0.0578 | 9.74:1 | PASS | PASS | 1.76:1 | FAIL | FAIL |
| default/other | --lwc-colorTextDefault | #3e3e3c | 0.0478 | 10.74:1 | PASS | PASS | 1.59:1 | FAIL | FAIL |

---

## Graph Search Highlight (`#FFB81C`) vs Node Base Colors

Highlight: `#FFB81C` — luminance 0.5570. Requirement: ≥ 3:1 (WCAG SC 1.4.11 UI component).

| Metadata Type | Node Hex | Node Luminance | Highlight Ratio | WCAG AA (≥3:1) |
|---|---|---|---|---|
| ApexClass / ApexTrigger | #0176d3 | 0.1766 | 2.71:1 | FAIL |
| Flow | #1b5297 | 0.0850 | 4.46:1 | PASS |
| CustomField | #2e844a | 0.1752 | 2.69:1 | FAIL |
| ValidationRule | #ba0517 | 0.1059 | 3.94:1 | PASS |
| WorkflowRule | #dd7a01 | 0.2930 | 1.77:1 | FAIL |
| Report | #444444 | 0.0578 | 5.52:1 | PASS |
| default/other | #3e3e3c | 0.0478 | 6.07:1 | PASS |

---

## Progress Bar

Fill `#0176d3` (L=0.1766) vs SLDS track `--lwc-colorBorder` (~`#dddbda`, L≈0.726):
- Ratio: (0.776) / (0.2266) = **3.42:1** — PASS (≥3:1 for UI components)

---

## Failures and Required Fixes

### Dark Background (#1B1B1B) — 6 of 8 rows fail

| Type | Hex | Dark Contrast | Failure | Recommended Fix |
|---|---|---|---|---|
| ApexClass / ApexTrigger | #0176d3 | 3.69:1 | Normal text (node labels) | Lighten to `#3d8edb` (~4.6:1 on dark) for dark-mode label color, or use white labels on colored fills |
| Flow | #1b5297 | 2.20:1 | Normal text AND Large/UI | REPLACEMENT NEEDED — lighten to `#5a9fd4` (~4.6:1 on dark) |
| CustomField | #2e844a | 3.67:1 | Normal text (node labels) | Lighten to `#4caf70` (~4.5:1 on dark) for dark-mode label color |
| ValidationRule | #ba0517 | 2.54:1 | Normal text AND Large/UI | REPLACEMENT NEEDED — lighten to `#f56b6b` (~5.2:1 on dark) |
| Report | #444444 | 1.76:1 | Normal text AND Large/UI | REPLACEMENT NEEDED — lighten to `#9e9e9e` (~5.5:1 on dark) |
| default/other | #3e3e3c | 1.59:1 | Normal text AND Large/UI | REPLACEMENT NEEDED — lighten to `#9e9e9e` (~5.5:1 on dark) |

**Recommended approach for dark mode:** Use white (`#FFFFFF`) label text over colored node fills in dark mode. White text on all six failing node colors achieves ≥4.5:1 because each node fill luminance is ≤0.293 (see luminance column above). This requires rendering labels as white in dark mode rather than inheriting the node fill color as the text color.

### Light Background (#FFFFFF) — 1 failure

| Type | Hex | Light Contrast | Failure | Recommended Fix |
|---|---|---|---|---|
| WorkflowRule | #dd7a01 | 3.06:1 | Normal text | Darken to `#b35a00` (~4.6:1 on white). Current passes 3:1 for large text/UI borders. Only node label text fails. |

### Graph Search Highlight — 3 failures

| Type | Hex | Highlight Ratio | Recommended Fix |
|---|---|---|---|
| ApexClass / ApexTrigger | #0176d3 | 2.71:1 | Increase `borderWidth` to 4 and add `shadowBlur: 8` to provide visual distinction independent of color ratio |
| CustomField | #2e844a | 2.69:1 | Same as above |
| WorkflowRule | #dd7a01 | 1.77:1 | Same as above |

---

## Implementation Gate

Do not begin LWC implementation until every cell in the matrix relevant to the use case shows PASS:
- Node label text: must pass **4.5:1** on both `#FFFFFF` and `#1B1B1B`
- Node border and icon: must pass **3:1** on both backgrounds
- Graph search highlight border: must pass **3:1** against node base colors (or supplement with shadow as noted above)
- Confidence badge text on badge background: must pass **4.5:1** (add to this matrix when badge palette is chosen)
- Progress bar fill on track: must pass **3:1** — currently 3.42:1, PASS

*All ratios computed using WCAG 2.1 formula. Verify against actual rendered output with Lighthouse, axe, or the Salesforce Accessibility Checker before shipping.*

---

## Fix Verification Log

**Applied (metaMapperGraph.js), July 12, 2026:**
- `WorkflowRule` `TYPE_COLORS` entry changed from `#dd7a01` to `#b35a00` per the "Light Background" recommended fix above.
- `_buildOption()` now sets an explicit per-node `label.color`: white (`#FFFFFF`) when `document.body.classList.contains('slds-theme_inverse')` is true (dark theme), otherwise the node's type color (`baseColor`) - implementing the "Recommended approach for dark mode" white-label-text strategy described above, instead of lightening each of the six failing hex values individually.

**Not yet verified:** These are calculated-ratio fixes only. No live Lighthouse, axe, or Salesforce Accessibility Checker run was performed in this environment to confirm the rendered contrast - that check still needs to be run against a deployed org before shipping, per the Implementation Gate above.
