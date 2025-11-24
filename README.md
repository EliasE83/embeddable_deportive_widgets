# 🏒 Sports Widgets Platform

> Embeddable Flutter Web widgets for real-time sports data visualization

[![Flutter](https://img.shields.io/badge/Flutter-3.8+-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0+-0175C2?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A modular platform for embedding interactive sports widgets into any website. Built with Flutter Web and optimized for real-time data updates, responsive design, and seamless integration.

## ✨ Features

- **Real-time Updates** - WebSocket integration for live game scores and stats
- **Responsive Design** - Optimized for desktop, tablet, and mobile devices
- **Embeddable** - Easy integration into any website via iframe or direct embed
- **Customizable** - Theme support via CSS variables
- **Performance Optimized** - Image caching, lazy loading, and efficient rendering
- **Multi-league Support** - Configurable for different sports leagues and organizations

## 🎯 Widgets

### Scoreboard Widget
Displays live game scores with real-time updates.

**Features:**
- Live game status (Pre-game, In Progress, Final)
- Real-time score updates via WebSocket
- Period/clock information
- Goal scorers and game events
- Date navigation (previous/next day, date picker)
- Team logos and branding

**Use Cases:**
- League homepage scoreboards
- Team schedule pages
- Live game tracking

### Season Standing Widget
Shows team standings and statistics for a season.

**Features:**
- Multiple views: Division, Conference, League
- Comprehensive statistics (GP, W, L, OTL, SOL, PTS, etc.)
- Advanced metrics (KRACH, SOS, PP%, PK%)
- Sortable columns
- Season and stat class filters
- Responsive table design with horizontal scroll

**Use Cases:**
- League standings pages
- Team comparison tools
- Statistical analysis dashboards

## 🚀 Quick Start

### Prerequisites

```bash
# Flutter SDK 3.8.1 or higher
flutter --version

# Dart SDK 3.0 or higher
dart --version
```

### Installation

1. **Clone the repository**
```bash
git clone <repository-url>
cd embeddable_deportive_widgets
```

2. **Install dependencies for each widget**
```bash
# Scoreboard Widget
cd scoreboard_widget
flutter pub get

# Season Standing Widget
cd ../season_standing_widget
flutter pub get
```

3. **Configure environment variables**

Create `.env` files in each widget directory:

```env
# scoreboard_widget/.env
API_USERNAME=your_username
API_SECRET=your_secret_key
API_URL=api.example.com
LEAGUE_ID=1
```

```env
# season_standing_widget/.env
API_USERNAME=your_username
API_SECRET=your_secret_key
API_URL=api.example.com
LEAGUE_ID=1
SEASON_ID=7
```

4. **Build for web**
```bash
# Build Scoreboard Widget
cd scoreboard_widget
flutter build web 

# Build Season Standing Widget
cd ../season_standing_widget
flutter build web
```

### Embedding in Your Website

#### Option 1: Direct Embed

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Scoreboard</title>
  
  <!-- CSS Variables for theming -->
  <style>
    :root {
      --app-primary-red: #dd1e36;
      --app-primary-blue: #0c233f;
      --app-text-color: #000000;
      --app-secondary-white: #ffffff;
      --app-tertiary-grey: #9ea1a6;
      --app-font-family: 'Roboto', sans-serif;
    }
  </style>
  
  <!-- Optional: Override configuration -->
  <script>
    window.customConfiguration = {
      username: "your_username",
      secret: "your_secret",
      api_url: "api.example.com",
      league_id: "2"
    };
  </script>
</head>
<body>
  <div id="flutter-container"></div>
  
  <script src="app.js"></script>
  <script>
    window.flutterWidgetPath = "scoreboard_widget/build/web/";
    loadFlutter();
  </script>
</body>
</html>
```

## 🏗️ Architecture

### Project Structure

```
.
├── app.js                          # Modern widget loader with routing
├── old_app.js                      # Legacy loader for generic widgets
├── scoreboard_widget.html          # Scoreboard integration page
├── season_standing_widget.html     # Standings integration page
│
├── scoreboard_widget/              # Scoreboard Flutter app
│   ├── lib/
│   │   ├── main.dart              # App entry point
│   │   ├── scoreboard_widget.dart # Main widget logic
│   │   ├── img_job.dart           # Image caching system
│   │   ├── retry_image.dart       # Image loading with retry
│   │   └── services/
│   │       └── api_service.dart   # API communication
│   ├── pubspec.yaml
│   └── .env
│
└── season_standing_widget/         # Standings Flutter app
    ├── lib/
    │   ├── main.dart              # App entry point
    │   ├── season_standings_widget.dart
    │   ├── img_job.dart           # Image caching system
    │   └── services/
    │       └── api_service.dart   # API communication
    ├── pubspec.yaml
    └── .env
```

### Widget Loader System

The `app.js` file implements an intelligent routing system:

```javascript
// Automatically detects widget type and loads appropriate loader
window.loadFlutter = async function() {
  const widgetPath = window.flutterWidgetPath || 'flutter/';
  const key = detectWidgetKey(widgetPath);
  
  if (isSpecialWidget(key)) {
    // Advanced features: dynamic height, WebSocket, mobile optimization
    return loadFlutter_special();
  } else {
    // Basic features: standard rendering
    return loadFlutter_generic();
  }
}
```

**Special Widgets** (use `loadFlutter_special`):
- `scoreboard_widget` - Real-time updates, WebSocket support
- `season_standing_widget` - Dynamic height management
- `game_center_widget` - Live game details
- `season_schedule_widget` - Calendar integration
- `player_profile_widget` - Player statistics

**Generic Widgets** (use `loadFlutter_generic`):
- Custom or third-party widgets
- Simple display widgets without real-time features

### Communication Flow

```
┌─────────────────┐
│   HTML Page     │
│  (Parent Site)  │
└────────┬────────┘
         │
         │ 1. Loads app.js
         │ 2. Calls loadFlutter()
         │
┌────────▼────────┐
│   app.js        │
│  (Router)       │
└────────┬────────┘
         │
         │ 3. Detects widget type
         │ 4. Loads Flutter runtime
         │
┌────────▼────────┐
│ Flutter Widget  │
│  (Dart/Web)     │
└────────┬────────┘
         │
         │ 5. Fetches data
         │ 6. Reports height
         │ 7. Updates in real-time
         │
┌────────▼────────┐
│   Sports Data   │
│      API        │
└─────────────────┘
```

## ⚙️ Configuration

### CSS Variables (Theming)

Customize widget appearance by defining CSS variables in your parent page:

```css
:root {
  --app-primary-red: #dd1e36;        /* Primary accent color */
  --app-primary-blue: #0c233f;       /* Primary brand color */
  --app-text-color: #000000;         /* Main text color */
  --app-secondary-white: #ffffff;    /* Background/contrast color */
  --app-tertiary-grey: #9ea1a6;      /* Secondary text/borders */
  --app-font-family: 'Roboto', sans-serif;
}
```

### JavaScript Configuration

Override API credentials and settings:

```javascript
window.customConfiguration = {
  username: "api_username",
  secret: "api_secret_key",
  api_url: "api.example.com",
  league_id: "2",
  season: "129"  // Optional: specific season
};
```

### URL Parameters

Control widget behavior via query parameters:

**Scoreboard Widget:**
```
?date=2024-11-24&league_id=2&season=129&level_id=5&division_id=3
```

**Season Standing Widget:**
```
?season=129&tab=0&sortColumn=pts&sortAscending=false&level_id=5
```

### Ad Space Configuration

Add advertising space via HTML data attributes:

```html
<div id="flutter-container"
     data-ad-type="image"
     data-ad-src="https://example.com/banner.jpg"
     data-ad-link="https://example.com/promo">
</div>
```

Supported types: `image`, `video`

## 🔌 API Integration

### Authentication

The platform uses HMAC-SHA256 authentication:

```dart
// Automatic signature generation
final uri = ApiService.generateLink('get_schedule', moreQueries: {
  'league_id': '2',
  'date': '2024-11-24'
});

// Includes: auth_key, auth_timestamp, auth_signature, body_md5
```

### Available Endpoints

The platform integrates with a sports data API that provides the following endpoints:

| Endpoint | Purpose | Widget |
|----------|---------|--------|
| `get_schedule` | Fetch games for a date | Scoreboard |
| `get_game_center` | Get game details | Scoreboard |
| `get_standings` | Fetch team standings | Standings |
| `get_special_teams_stats` | PP% and PK% stats | Standings |
| `get_leagues` | League and season info | Both |

> **Note:** You'll need to configure your own API backend that implements these endpoints.

### WebSocket Integration

Real-time updates for live games:

```javascript
// Automatic connection for in-progress games
socket.on('clock', (data) => {
  // Updates: score, period, clock, events
  updateGameState(data);
});
```

**Channels:**
- `game_center_channel` - Game-specific updates
- `rink_center_channel` - Venue-specific updates

## 💻 Development

### Running Locally

```bash
# Scoreboard Widget
cd scoreboard_widget
flutter run -d chrome --web-port=8080

# Season Standing Widget
cd season_standing_widget
flutter run -d chrome --web-port=8081
```

### Hot Reload

Flutter's hot reload works in web mode:
```bash
# Press 'r' in terminal to hot reload
# Press 'R' to hot restart
```

### Debug Mode

Enable Flutter DevTools:
```bash
flutter run -d chrome --web-port=8080 --dart-define=FLUTTER_WEB_USE_SKIA=true
```

### Testing Integration

Test widgets in the provided HTML files:
```bash
# Serve files locally
python3 -m http.server 8000

# Open in browser
open http://localhost:8000/scoreboard_widget.html
```
