# maintenance
CA UIM - Maintenance probe

## Config

```xml
<setup>
    loglevel = 3
    logsize = 8192
    nim_login = administrator
    nim_password =
    maintenance_mode =
</setup>
<uimapi>
    api_host =
    api_protocol = http
    api_port = 8080
    api_user =
    api_pass =
</uimapi>
<messages>
   default_origin =
   <callback_failed>
      message = Callback $callback failed on Source $source
      token = 
      severity = 1
      subsystem = 1.1.
      supp_key = cbfail_$callback_$source
      variables = $callback,$source
   </callback_failed>
   <device_id_failed>
      message = HTTP Request to '$api' failed for source '$source'
      token = 
      severity = 1
      subsystem = 1.1.
      supp_key = device_id_failed_$source
      variables = $api,$source
   </device_id_failed>
</messages>
```

> **nim_login** and **nim_password** are not required for a probe.
