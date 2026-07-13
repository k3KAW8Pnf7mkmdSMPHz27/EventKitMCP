// EventKitService - Apple Reminders EventKit Integration
//
// This module provides a clean Swift interface for Apple Reminders via EventKit.
// It includes:
// - ReminderService: Main service for CRUD operations on reminders
// - Models: Swift representations of reminders and lists
// - Error handling for EventKit operations

import Foundation

// Re-export models
public typealias Reminder = ReminderModel
public typealias ReminderList = ReminderListModel

// Version Info
public let eventKitServiceVersion = "1.0.0"
