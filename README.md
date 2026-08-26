# Restaurant Reservations

A restaurant reservation and ordering platform: a single web application serving three user roles: **Customer**, **Employee**, and **Owner**.

> **Status:** early planning / pre-implementation. Tech stack and architecture chosen (single Next.js app + Supabase + Stripe — see [CLAUDE.md](CLAUDE.md)); no application code has been written yet.

## Applications

### Shared (all applications)

- Account creation
- Log in / log out
- Account deletion

### Customer

- Browse restaurants, ranked by an ML-driven recommendation algorithm
- Search for restaurants
- View restaurants on a map
- Make a reservation (time and party size required; optionally a restaurant section such as smoking/non-smoking or indoor/outdoor, or a specific table chosen from a layout created by the owner)
- Place an order alongside a reservation (standard food-delivery-app-style ordering, similar to Wolt/Glovo)
- Pay by debit card
- Cancel a reservation
- View past reservations
- View current reservations
- Receive notifications about reservation/order status

### Employee

- Browse and search restaurants, similar to the customer app
- Send a request to a restaurant owner to be accepted as an employee at that restaurant
- View customers' current reservations
- Change the status of customers' reservations

### Owner

- Add / remove employees
- Set and change the restaurant's image, name, working hours, and other standard attributes
- Add / change / remove menu items (also similar to Wolt/Glovo)
- Add restaurant sections that customers can choose when making a reservation
- Create the restaurant's table layout

## Repository structure

A single Next.js application at the repo root — not a monorepo of separate apps. The three roles are organized internally as route groups so role-specific code stays cleanly separated within the one app, without the overhead of three separate deployments for a pre-launch product. See [CLAUDE.md](CLAUDE.md) for the full reasoning and current tech stack.

## Getting started

No setup instructions yet — the codebase hasn't been started.

## License

TBD.
