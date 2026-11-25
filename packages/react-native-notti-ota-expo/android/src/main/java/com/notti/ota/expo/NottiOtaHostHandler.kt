package com.notti.ota.expo

import android.util.Log
import expo.modules.core.interfaces.ReactNativeHostHandler

internal class NottiOtaHostHandler : ReactNativeHostHandler {

  override fun getJSBundleFile(useDeveloperSupport: Boolean): String? {
    Log.i(TAG, "Live updates: Expo bundle hook called (developer support: $useDeveloperSupport)")
    return null
  }

  // Expo stops propagating instance errors once any handler is registered; rethrowing keeps a
  // fatal JS error a crash instead of a blank screen.
  override fun onReactInstanceException(useDeveloperSupport: Boolean, exception: Exception) {
    throw exception
  }

  private companion object {
    const val TAG = "NottiOta"
  }
}
