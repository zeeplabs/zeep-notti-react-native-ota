package com.notti.ota.expo

import expo.modules.core.interfaces.ReactNativeHostHandler

/** Loads the bundle Notti Live updates selected; null lets Expo use its default bundle. */
internal class NottiOtaHostHandler(private val selectBundle: () -> String?) : ReactNativeHostHandler {

  override fun getJSBundleFile(useDeveloperSupport: Boolean): String? =
    if (useDeveloperSupport) null else selectBundle()

  // Expo stops propagating instance errors once any handler is registered; rethrowing keeps a
  // fatal JS error a crash instead of a blank screen.
  override fun onReactInstanceException(useDeveloperSupport: Boolean, exception: Exception) {
    throw exception
  }
}
