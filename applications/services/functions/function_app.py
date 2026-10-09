"""hello-functions - Azure Functions Python v2 programming model.

Functions (disable per hosting plan with app setting AzureWebJobs.<name>.Disabled=true):
  audit         Service Bus topic trigger order-events / subscription audit. Identity-based connection:
                ServiceBusConnection__fullyQualifiedNamespace=<ns>.servicebus.windows.net
                (+ ServiceBusConnection__credential=managedidentity, ServiceBusConnection__clientId=<uami client id>)
  cache_warmer  timer, every 5 minutes (NCRONTAB "0 */5 * * * *")
  quote         HTTP GET /api/quote?sku=SKU-0001&quantity=2 (anonymous; private ingress only)
"""

import json
import logging

import azure.functions as func

from hello_functions import bootstrap, handlers

bootstrap.configure()
log = logging.getLogger("hello_functions")
app = func.FunctionApp()


@app.function_name(name="audit")
@app.service_bus_topic_trigger(arg_name="msg", topic_name="order-events", subscription_name="audit", connection="ServiceBusConnection")
def audit(msg: func.ServiceBusMessage) -> None:
    handlers.handle_audit(msg.get_body(), msg.message_id or "", msg.application_properties, handlers.audit_sink_from_env())


@app.function_name(name="cache_warmer")
@app.timer_trigger(arg_name="timer", schedule="0 */5 * * * *", run_on_startup=False, use_monitor=True)
def cache_warmer(timer: func.TimerRequest) -> None:
    if timer.past_due:
        log.warning("cache warmer timer is past due")
    handlers.warm_cache()


@app.function_name(name="quote")
@app.route(route="quote", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def quote(req: func.HttpRequest) -> func.HttpResponse:
    status, body = handlers.quote(req.params.get("sku"), req.params.get("quantity"))
    mimetype = "application/json" if status == 200 else "application/problem+json"
    return func.HttpResponse(json.dumps(body), status_code=status, mimetype=mimetype)
