/**
 * React Native entry point (iOS/Android)
 * Used by Metro bundler when building for mobile devices
 */

import { AppRegistry } from 'react-native'
import App from './App'
import { name as appName } from '../app.json'

// Register the main application component
AppRegistry.registerComponent(appName, () => App)
