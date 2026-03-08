# Implementation Best Practices

No project-specific implementation summary was generated for this feature. Use the following general guidelines to inform your work.

## Phoenix / Elixir Patterns

- Follow the Context pattern: group related functionality into context modules
- Use Ecto changesets for data validation
- Keep controllers/LiveViews thin; put business logic in contexts
- Use pattern matching and `with` expressions for control flow
- Handle errors explicitly with tagged tuples (`{:ok, result}` / `{:error, reason}`)

## Code Organization

- Place context modules in `lib/app_name/` (e.g., `lib/app/accounts/`)
- Place web modules in `lib/app_name_web/` (e.g., `lib/app_web/live/`)
- Use descriptive module and function names
- Keep functions short and focused on a single responsibility

## Database

- Write reversible migrations when possible
- Use `Ecto.Multi` for operations that must succeed or fail together
- Add database-level constraints (unique indexes, foreign keys, NOT NULL)
- Use `Repo.preload/2` for loading associations, avoid N+1 queries

## Security

- Validate and sanitize all user input
- Use parameterized queries (Ecto handles this by default)
- Scope queries to the current user/organization where appropriate
- Never expose internal IDs or error details to end users

## LiveView

- Use streams for large or dynamic collections
- Minimize assigns to what the template actually needs
- Handle both connected and disconnected socket states in `mount/3`
- Use `assign_async/3` or `start_async/3` for expensive operations
