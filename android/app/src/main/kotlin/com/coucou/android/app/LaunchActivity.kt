package com.coucou.android.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.coucou.android.MainActivity

/**
 * Where our own notification actions, the island's Allow and the widget rows land. It is not exported, so no other app can start it;
 * it passes the request to the app inside the process ([PendingLaunch]) and opens MainActivity with a plain intent.
 */
class LaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val model = (application as CoucouApp).model
        val session = intent.getStringExtra(EXTRA_SESSION)
        // A widget row asks for a session to open; a notification asks for an Allow. Each has its own slot, and one
        // never clears the other.
        if (session != null) model.launch.requestSession(session)
        else model.launch.request(intent.getStringExtra(Notifications.EXTRA_FP), intent.getBooleanExtra(Notifications.EXTRA_ALLOW, false))
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
        finish()
    }

    companion object {
        /** The pill id of the session a widget row opens. */
        const val EXTRA_SESSION = "session"
    }
}
