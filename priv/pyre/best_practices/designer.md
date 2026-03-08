# Design Best Practices

No project-specific design specification was generated for this feature. Use the following general guidelines to inform your work.

## Component Patterns

- Use Phoenix CoreComponents (`<.input>`, `<.button>`, `<.table>`, `<.modal>`) as building blocks
- Break pages into small, focused function components
- Use Tailwind CSS utility classes for styling
- Follow mobile-first responsive design

## LiveView State Management

- Use `assigns` for scalar data and `streams` for collections
- Initialize all assigns in `mount/3`
- Use `to_form/1` for form state management
- Handle loading, empty, and error states explicitly

## User Interactions

- Use `phx-submit` for form submissions, `phx-change` for live validation
- Use `<.link navigate={...}>` for page navigation, `<.link patch={...}>` for same-page updates
- Provide clear feedback for user actions (flash messages, inline validation)
- Design for keyboard navigation and accessibility (labels, ARIA attributes)

## Layout

- Use consistent page structure with headers, content areas, and navigation
- Include breadcrumbs or back links for nested pages
- Design empty states that guide the user toward action
- Keep visual hierarchy clear with appropriate heading levels and spacing
