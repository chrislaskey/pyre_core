# Testing Best Practices

No project-specific test summary was generated for this feature. Use the following general guidelines to inform your work.

## Test Organization

- Place tests in `test/` mirroring the `lib/` directory structure
- Use `ExUnit.Case` with `async: true` when tests don't share state
- Group related tests with `describe` blocks
- Name tests clearly: "verb + condition + expected outcome"

## What to Test

- Context functions: CRUD operations, validations, business rules
- LiveView pages: mounting, rendering, user interactions, form submissions
- Edge cases: empty inputs, boundary values, authorization failures
- Error paths: invalid data, missing records, constraint violations

## Testing Patterns

- Use `setup` blocks for shared test fixtures
- Use factories or fixture functions to create test data
- Test one behavior per test case
- Assert on specific values, not just shape (e.g., assert the actual error message)

## LiveView Testing

- Use `Phoenix.LiveViewTest` for integration tests
- Test `mount/3` renders the expected content
- Test form interactions with `form/3` and `submit_form/3`
- Test navigation with `follow_redirect/2`
- Test PubSub updates by sending messages directly

## Context Testing

- Test changeset validations with invalid data
- Test query functions with various filter combinations
- Test authorization/scoping logic
- Use `Ecto.Adapters.SQL.Sandbox` for database isolation
