# Architecture

## System Overview

Compact Sales Monitoring is a role-based Flutter application backed by Firebase. The app serves three user types from one codebase:

- Salesman
- Supervisor
- Superuser

Each role receives a different tab layout through the shared app router after authentication.

## High-Level Layers

```text
Flutter App
  UI Screens and Widgets
  Provider State
  Service Layer
  Firebase Backend
```

## Routing Model

Authentication is handled first. After login, the app resolves the destination screen by role.

```text
LoginScreen
  -> AuthProvider
  -> AuthService
  -> Firestore user lookup
  -> AppRouter
       -> SalesmanTabsScreen
       -> SupervisorTabsScreen
       -> SuperuserTabsScreen
```

## Role-Based Screen Structure

### Salesman

- Calls tab
- Agile tab

Primary responsibilities:

- capture first and last call images
- collect GPS metadata
- store route progress and checkpoints
- submit daily Agile actuals

### Supervisor

- Home tab
- Map tab
- Agile tab

Primary responsibilities:

- review assigned salesmen
- inspect routes by date
- preview route details
- set Agile targets per salesman and day
- compare actual values against targets

### Superuser

- Home tab
- Map tab
- Agile tab
- User Management flow

Primary responsibilities:

- view all supervisors and teams
- inspect all routes globally
- archive route history
- review Agile performance rollups
- create and maintain user accounts

## State Management

The app uses Provider for shared state.

### AuthProvider

Responsibilities:

- login and logout
- maintain authenticated user state
- restore user session
- expose loading and error state

### RouteProvider

Responsibilities:

- fetch routes by date
- fetch global routes for superuser
- generate or reuse route polylines
- track approximate fallback polylines when routing is unavailable

## Service Layer

### AuthService

- wraps Firebase Authentication
- fetches the signed-in user profile from Firestore

### FirestoreService

- user CRUD and assignment logic
- route CRUD and lookup logic
- Agile target persistence
- Agile submission persistence
- archive and administrative support helpers

### StorageService

- uploads route images to Firebase Storage

### LocationService

- retrieves device location
- supports route capture and checkpoint logic

### RoutingService

- resolves road-aware route segments
- supports map polyline generation

## Core User Flows

### Salesman Call Capture

```text
Salesman opens Calls tab
  -> capture image
  -> fetch current location
  -> stamp image details and QR link
  -> upload to Firebase Storage
  -> save route data in Firestore
  -> update UI state
```

### Salesman Agile Submission

```text
Salesman opens Agile tab
  -> load existing submission for selected day
  -> validate totals and submission rules
  -> confirm submission
  -> save to agile_submissions
  -> lock finalized state
```

### Supervisor Agile Target Management

```text
Supervisor opens Agile tab
  -> load assigned team
  -> load agile_targets for selected day
  -> load agile_submissions for selected day
  -> edit targets per salesman
  -> save to agile_targets
  -> review actual vs target metrics
```

### Route Monitoring Flow

```text
Supervisor or Superuser opens Map tab
  -> choose date
  -> fetch routes from Firestore
  -> load cached polyline or request route segments
  -> render map markers and polylines
  -> open route detail preview when selected
```

### Superuser Administration

```text
Superuser opens user management
  -> fetch users by role
  -> create or edit user
  -> assign supervisor when needed
  -> activate, deactivate, or delete account
  -> optionally update credentials through Cloud Functions
```

## Firebase Data Model

### users

Stores identity and role information.

Typical fields:

- uid
- email
- name
- role
- active
- supervisorId
- profilePic
- createdAt

### routes

Stores route activity and call data.

Typical fields:

- salesmanId
- supervisorId
- date
- first
- last
- hasFirstCall
- hasLastCall
- checkpoints
- cachedPolyline
- distance
- retake flags

### agile_targets

Stores supervisor-entered targets.

Typical fields:

- supervisorId
- salesmanId
- date
- productiveCallsTarget
- sttTarget
- updatedAt

### agile_submissions

Stores salesman-entered daily actuals.

Typical fields:

- supervisorId
- salesmanId
- date
- totalCalls
- productiveCalls
- sttActual
- lastCallCompleted
- submitted
- submittedAt

## Security Model

Firestore rules enforce role-based access.

- salesmen can access their own route and Agile submission data
- supervisors can access their assigned team data and set targets
- superusers can access all operational data

Current rules are defined in `firestore.rules`.

## Important Files

- `lib/app_router.dart`
- `lib/providers/auth_provider.dart`
- `lib/providers/route_provider.dart`
- `lib/services/firestore_service.dart`
- `lib/models/route_model.dart`
- `lib/models/agile_model.dart`
- `lib/widgets/agile_call_form_card.dart`
- `lib/screens/salesman/salesman_tabs_screen.dart`
- `lib/screens/supervisor/supervisor_tabs_screen.dart`
- `lib/screens/superuser/superuser_tabs_screen.dart`

## Current Validation State

- Documentation aligned with implemented app behavior
- Flutter analyzer clean
