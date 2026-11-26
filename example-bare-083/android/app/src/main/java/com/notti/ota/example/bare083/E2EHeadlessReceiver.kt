package com.notti.ota.example.bare083

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Example app only: the e2e flows broadcast to it to start the process without any Activity, the
 * way a data push does. Live updates must not count such a start as a launch.
 */
class E2EHeadlessReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) = Unit
}
