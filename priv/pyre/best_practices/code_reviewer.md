# Code Review Best Practices

No project-specific code review was performed for this feature. Use the following general guidelines to evaluate the work.

## Code Quality Checklist

- Functions are small, focused, and well-named
- Modules have clear responsibilities and don't mix concerns
- Pattern matching is used effectively for control flow
- Error handling is explicit (no silent failures)
- No dead code, unused variables, or commented-out blocks

## Phoenix-Specific Checks

- LiveView assigns are minimal and initialized in `mount/3`
- Database queries are efficient (no N+1, proper indexes)
- Changesets validate all required fields and constraints
- Routes follow RESTful conventions
- Templates use CoreComponents consistently

## Security Review

- User input is validated and sanitized
- Database queries are parameterized (Ecto default)
- Authorization checks are in place for protected resources
- Sensitive data is not logged or exposed in error messages

## Test Coverage

- Core business logic has unit tests
- LiveView pages have integration tests for key flows
- Edge cases and error paths are tested
- Tests are independent and don't rely on execution order

## General Standards

- Code follows the project's existing conventions and patterns
- New dependencies are justified and well-maintained
- Documentation is added for complex or non-obvious logic
- Changes are focused and don't include unrelated modifications
