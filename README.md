# Restaurant Reservations

A restaurant reservation and ordering platform made up of three separate web applications, one per user role: **Customer**, **Employee**, and **Owner**.

> **Status:** early planning / pre-implementation. No tech stack has been chosen yet — this document describes the intended scope and will evolve as architecture decisions are made.

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

Not yet decided. Options under consideration include a monorepo with one directory per application (`customer/`, `employee/`, `owner/`) and a shared backend/API, versus separate services per app. This section will be updated once the architecture is settled.

## Getting started

No setup instructions yet — the codebase hasn't been started.

## License

TBD.
