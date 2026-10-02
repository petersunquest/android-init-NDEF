package com.beamio.app

import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.stripe.stripeterminal.Terminal
import com.stripe.stripeterminal.external.callable.Callback
import com.stripe.stripeterminal.external.callable.Cancelable
import com.stripe.stripeterminal.external.callable.ConnectionTokenCallback
import com.stripe.stripeterminal.external.callable.ConnectionTokenProvider
import com.stripe.stripeterminal.external.callable.DiscoveryListener
import com.stripe.stripeterminal.external.callable.PaymentIntentCallback
import com.stripe.stripeterminal.external.callable.ReaderCallback
import com.stripe.stripeterminal.external.callable.TerminalListener
import com.stripe.stripeterminal.external.models.ConnectionConfiguration.BluetoothConnectionConfiguration
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration.BluetoothDiscoveryConfiguration
import com.stripe.stripeterminal.external.models.ConnectionStatus
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration
import com.stripe.stripeterminal.external.models.PaymentIntent
import com.stripe.stripeterminal.external.models.Reader
import com.stripe.stripeterminal.external.models.ConnectionConfiguration.TapToPayConnectionConfiguration
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration.TapToPayDiscoveryConfiguration
import com.stripe.stripeterminal.external.models.EasyConnectConfiguration.TapToPayEasyConnectConfiguration
import com.stripe.stripeterminal.external.models.TapUseCase
import com.stripe.stripeterminal.external.models.TerminalException
import com.stripe.stripeterminal.log.LogLevel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Native-only Stripe Terminal adapter. It deliberately receives only a
 * PaymentIntent client secret and a card address; it never receives a Stripe
 * secret key or a wallet private key.
 */
class StripeTerminalPosBridge(
    private val activity: MainActivity,
    private val emit: (JSONObject) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var requestId = ""
    private var paymentIntentId = ""
    private var clientSecret = ""
    private var cardAddress = ""
    private var locationId = ""
    private var buyerEoa = ""
    private var amountFiat6 = ""
    private var currency = ""
    private var kind = "topup"
    private var businessIdempotencyKey = ""
    private var posAdmin = ""
    private var authorizationSignature = ""
    private var authorizationDeadline = 0
    private var authorizationNonce = ""
    private var pendingStartRaw: String? = null
    private var operation = 0
    private var activeCancelable: Cancelable? = null
    private var timeout: Runnable? = null
    private var acceptingContinuation = false

    private val tokenProvider = object : ConnectionTokenProvider {
        override fun fetchConnectionToken(callback: ConnectionTokenCallback) {
            val card = cardAddress
            io.execute {
                try {
                    val url = URL("https://beamio.app/api/merchantCardStripe/connectionToken")
                    val connection = (url.openConnection() as HttpURLConnection).apply {
                        requestMethod = "POST"
                        doOutput = true
                        setRequestProperty("Content-Type", "application/json")
                    }
                    connection.outputStream.use {
                        it.write(
                            JSONObject()
                                .put("cardAddress", card)
                                .put("buyerEoa", buyerEoa)
                                .put("amountFiat6", amountFiat6)
                                .put("currency", currency)
                                .put("kind", kind)
                                .put("businessIdempotencyKey", businessIdempotencyKey)
                                .put("posAdmin", posAdmin)
                                .put("authorizationSignature", authorizationSignature)
                                .put("authorizationDeadline", authorizationDeadline)
                                .put("authorizationNonce", authorizationNonce)
                                .toString()
                                .toByteArray(),
                        )
                    }
                    val text = connection.inputStream.bufferedReader().use { it.readText() }
                    val json = JSONObject(text)
                    if (connection.responseCode !in 200..299) {
                        throw IllegalStateException(json.optString("error", "Connection token request failed"))
                    }
                    callback.onSuccess(json.getString("secret"))
                } catch (error: Exception) {
                    callback.onFailure(
                        com.stripe.stripeterminal.external.models.ConnectionTokenException(
                            error.message ?: "Connection token request failed",
                        ),
                    )
                }
            }
        }
    }

    private val terminalListener = object : TerminalListener {
        override fun onConnectionStatusChange(status: ConnectionStatus) = Unit
        override fun onPaymentStatusChange(status: com.stripe.stripeterminal.external.models.PaymentStatus) = Unit
    }

    fun start(raw: String) {
        try {
            if (!acceptingContinuation) {
                val previousRequestId = requestId
                val previousPaymentIntentId = paymentIntentId
                cancelStripeWork()
                if (previousRequestId.isNotBlank()) {
                    emit(
                        JSONObject()
                            .put("action", "stripePhysicalPaymentResult")
                            .put("requestId", previousRequestId)
                            .put("paymentIntentId", previousPaymentIntentId)
                            .put("errorCode", "superseded")
                            .put("error", "Physical card payment was replaced by a new attempt.")
                            .put("ok", false),
                    )
                }
                operation += 1
            }
            val op = operation
            val request = JSONObject(raw)
            requestId = request.optString("requestId")
            paymentIntentId = request.optString("paymentIntentId")
            clientSecret = request.optString("clientSecret")
            cardAddress = request.optString("cardAddress")
            locationId = request.optString("locationId")
            buyerEoa = request.optString("buyerEoa")
            amountFiat6 = request.optString("amountFiat6")
            currency = request.optString("currency")
            kind = request.optString("kind", "topup")
            businessIdempotencyKey = request.optString("businessIdempotencyKey")
            posAdmin = request.optString("posAdmin")
            authorizationSignature = request.optString("authorizationSignature")
            authorizationDeadline = request.optInt("authorizationDeadline", 0)
            authorizationNonce = request.optString("authorizationNonce")
            if (
                requestId.isBlank() ||
                clientSecret.isBlank() ||
                cardAddress.isBlank() ||
                locationId.isBlank() ||
                buyerEoa.isBlank() ||
                amountFiat6.isBlank() ||
                currency.isBlank() ||
                businessIdempotencyKey.isBlank() ||
                posAdmin.isBlank() ||
                authorizationSignature.isBlank() ||
                authorizationDeadline <= 0 ||
                authorizationNonce.isBlank()
            ) {
                fail("invalid_request", "Stripe Terminal payment request is incomplete.")
                return
            }
            val hasLocationPermission =
                ContextCompat.checkSelfPermission(
                    activity,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(
                        activity,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ) == PackageManager.PERMISSION_GRANTED
            armTimeout(op)
            if (!hasLocationPermission) {
                pendingStartRaw = raw
                activity.requestStripeLocationPermission()
                return
            }
            if (!Terminal.isInitialized()) {
                Terminal.init(activity, LogLevel.NONE, tokenProvider, terminalListener, null)
            }
            val connectedReader = Terminal.getInstance().connectedReader
            if (connectedReader != null) {
                pendingStartRaw = raw
                Terminal.getInstance().disconnectReader(object : Callback {
                    override fun onSuccess() {
                        if (op != operation) return
                        val pending = pendingStartRaw
                        pendingStartRaw = null
                        if (pending != null) continueStart(pending)
                    }

                    override fun onFailure(e: TerminalException) {
                        if (op != operation) return
                        pendingStartRaw = null
                        fail("reader_disconnect_failed", e.errorMessage)
                        operation += 1
                    }
                })
                return
            }
            startReaderDiscovery(request.optString("readerMode", "auto"), op)
        } catch (error: Exception) {
            fail("terminal_initialization_failed", error.message ?: "Stripe Terminal could not start.")
        }
    }

    private fun continueStart(raw: String) {
        acceptingContinuation = true
        try {
            start(raw)
        } finally {
            acceptingContinuation = false
        }
    }

    private fun armTimeout(op: Int) {
        timeout?.let { main.removeCallbacks(it) }
        val runnable = Runnable {
            if (op != operation) return@Runnable
            cancelStripeWork()
            fail("timed_out", "Physical card payment timed out. Tap to Pay did not finish. Please try again.")
            operation += 1
        }
        timeout = runnable
        main.postDelayed(runnable, 90_000)
    }

    private fun cancelStripeWork() {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        try {
            activeCancelable?.cancel(object : Callback {
                override fun onSuccess() = Unit
                override fun onFailure(e: TerminalException) = Unit
            })
        } catch (_: Exception) {
            /* Terminal may not have an active command. */
        }
        activeCancelable = null
    }

    private fun startReaderDiscovery(mode: String, op: Int) {
        try {
            if (mode == "external_reader") {
                discoverBluetooth(op)
            } else {
                connectTapToPay(op)
            }
        } catch (error: Exception) {
            fail("terminal_initialization_failed", error.message ?: "Stripe Terminal could not start.")
            operation += 1
        }
    }

    fun onLocationPermissionResult(granted: Boolean) {
        val pending = pendingStartRaw
        pendingStartRaw = null
        if (!granted) {
            fail("location_permission_denied", "Location permission is required for Tap to Pay.")
            operation += 1
            return
        }
        if (pending != null) continueStart(pending)
    }

    private fun connectTapToPay(op: Int) {
        val terminal = Terminal.getInstance()
        activeCancelable = terminal.easyConnect(
            TapToPayEasyConnectConfiguration(
                TapToPayDiscoveryConfiguration(isSimulated = false),
                TapToPayConnectionConfiguration(TapUseCase.Pay(locationId)),
            ),
            readerCallback(op),
        )
    }

    private fun discoverBluetooth(op: Int) {
        activeCancelable = Terminal.getInstance().discoverReaders(
            BluetoothDiscoveryConfiguration(timeout = 30, isSimulated = false),
            object : DiscoveryListener {
                override fun onUpdateDiscoveredReaders(readers: List<Reader>) {
                    if (op != operation) return
                    val reader = readers.firstOrNull() ?: return
                    Terminal.getInstance().connectReader(
                        reader,
                        BluetoothConnectionConfiguration(locationId, true, object : com.stripe.stripeterminal.external.callable.MobileReaderListener {}),
                        readerCallback(op),
                    )
                }
            },
            object : Callback {
                override fun onSuccess() = Unit
                override fun onFailure(e: TerminalException) {
                    if (op != operation) return
                    fail("reader_unavailable", e.errorMessage)
                    operation += 1
                }
            },
        )
    }

    private fun readerCallback(op: Int) = object : ReaderCallback {
        override fun onSuccess(reader: Reader) {
            if (op != operation) return
            retrieveAndProcess(clientSecret, op)
        }
        override fun onFailure(e: TerminalException) {
            if (op != operation) return
            fail("reader_unavailable", e.errorMessage)
            operation += 1
        }
    }

    private fun retrieveAndProcess(clientSecret: String, op: Int) {
        Terminal.getInstance().retrievePaymentIntent(clientSecret, object : PaymentIntentCallback {
            override fun onSuccess(paymentIntent: PaymentIntent) {
                if (op != operation) return
                activeCancelable = Terminal.getInstance().processPaymentIntent(
                    paymentIntent,
                    com.stripe.stripeterminal.external.models.CollectPaymentIntentConfiguration.Builder().build(),
                    com.stripe.stripeterminal.external.models.ConfirmPaymentIntentConfiguration.Builder().build(),
                    object : PaymentIntentCallback {
                    override fun onSuccess(result: PaymentIntent) {
                        if (op != operation) return
                        succeed(result.status.toString())
                        operation += 1
                    }

                    override fun onFailure(e: TerminalException) {
                        if (op != operation) return
                        fail("payment_failed", e.errorMessage)
                        operation += 1
                    }
                    },
                )
            }

            override fun onFailure(e: TerminalException) {
                if (op != operation) return
                fail("payment_intent_unavailable", e.errorMessage)
                operation += 1
            }
        })
    }

    fun cancel(raw: String? = null) {
        val expected = raw?.let { runCatching { JSONObject(it).optString("requestId") }.getOrNull() }.orEmpty()
        if (expected.isNotBlank() && expected != requestId) return
        cancelStripeWork()
        fail("cancelled", "Physical card payment was cancelled.")
        operation += 1
    }

    private fun succeed(paymentStatus: String) {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        emit(
            JSONObject()
                .put("action", "stripePhysicalPaymentResult")
                .put("requestId", requestId)
                .put("paymentIntentId", paymentIntentId)
                .put("paymentStatus", paymentStatus)
                .put("ok", true),
        )
    }

    private fun fail(code: String, message: String) {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        emit(
            JSONObject()
                .put("action", "stripePhysicalPaymentResult")
                .put("requestId", requestId)
                .put("paymentIntentId", paymentIntentId)
                .put("errorCode", code)
                .put("error", message)
                .put("ok", false),
        )
    }
}
