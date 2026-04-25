# Project Summary

## Status

Complete and analyzer-clean as of April 2026.

## Project Overview

Compact Sales Monitoring is a multi-role Flutter application backed by Firebase for field sales operations. It combines route capture, map-based oversight, Agile target management, Agile submission tracking, and superuser administration in a single codebase.

## Implemented Roles

### Salesman

- Authenticated mobile workflow
- First-call and last-call capture with stamped images
- GPS-tagged route logging and checkpoints
- Agile daily submission form
- Submission locking after finalization

### Supervisor

- Home dashboard for assigned salesmen
- Map dashboard for team route review by date
- Agile dashboard for setting daily targets and viewing actuals
- Responsive wide and compact card layouts

### Superuser

- Home dashboard with supervisor rollups
- Global map dashboard with archive workflow
- Agile dashboard with supervisor-level performance summaries
- User management for creating, updating, assigning, activating, and deleting users
- Cloud Function-backed credential update support

## Current Feature Areas

### Route Monitoring

- First and last call image capture
- Checkpoints during the day
- GPS metadata and map links
- Firestore-backed routes collection
- Cached route polyline support
- Map previews and route detail dialogs
- Retake request and approval support

### Agile Monitoring

- Supervisor target entry per salesman and date
- Salesman actual submission per day
- Historical review via date selectors
- Supervisor and superuser aggregation views
- Firestore collections for targets and submissions
- Security rules aligned to role ownership

### Administration

- Role-based routing
- User provisioning and editing
- Active or inactive account state
- Supervisor assignment for salesmen
- Archive export flow from the superuser map page

## Main Technologies

- Flutter
- Provider
- Firebase Auth
- Cloud Firestore
- Firebase Storage
- Cloud Functions for Firebase
- flutter_map
- Geolocator
- Image Picker
- intl

## Important Files

- README.md
- lib/app_router.dart
- lib/screens/salesman/salesman_tabs_screen.dart
- lib/screens/supervisor/supervisor_tabs_screen.dart
- lib/screens/superuser/superuser_tabs_screen.dart
- lib/screens/supervisor/supervisor_agile_page.dart
- lib/screens/superuser/superuser_agile_page.dart
- lib/widgets/agile_call_form_card.dart
- lib/services/firestore_service.dart
- lib/models/agile_model.dart
- firestore.rules

## Current Firestore Collections

- users
- routes
- agile_targets
- agile_submissions

## Validation Snapshot

- flutter analyze: clean
- README updated to current app behavior
- Quick-start and Firebase docs aligned with implemented features

## Repository Summary

Compact Sales Monitoring provides role-based dashboards for salesman, supervisor, and superuser users, combining daily call capture, map-based route oversight, Agile target management, Agile submission tracking, and account administration on top of Firebase.
