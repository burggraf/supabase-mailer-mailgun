CREATE SCHEMA private;
CREATE TABLE private.keys (
    key text primary key not null,
    value text
);
REVOKE ALL ON TABLE private.keys FROM PUBLIC;

/****************************************************************
*  IMPORTANT:  INSERT YOUR KEYS IN THE 3 INSERT COMMANDS BELOW  *
*****************************************************************

-- [PERSONAL_MAILGUN_DOMAIN]

-- [PERSONAL_MAILGUN_API_KEY]
-- (looks like this): api:key-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

-- [SUPABASE_API_URL_HERE]
-- Supabase Dashboard / settings / api / config / url

-- [SUPABASE_PUBLIC_KEY_HERE]
-- Supabase Dashboard / settings / api / anon-public key
**************************************************************/

INSERT INTO private.keys (key, value) values ('MAILGUN_DOMAIN', '[PERSONAL_MAILGUN_DOMAIN]');
INSERT INTO private.keys (key, value) values ('MAILGUN_API_KEY', '[PERSONAL_MAILGUN_API_KEY]');
INSERT INTO private.keys (key, value) values ('MAILGUN_WEBHOOK_URL', 
    'https://[SUPABASE_API_URL_HERE]/rest/v1/rpc/mailgun_webhook?apikey=[SUPABASE_PUBLIC_KEY_HERE]');

/************************************************************
*  Create the messages table
************************************************************/

CREATE TABLE if not exists public.messages
(
    id uuid primary key default uuid_generate_v4(),
    recipient text,
    sender text,
    cc text,
    bcc text,
    subject text,
    text_body text,
    html_body text,
    created timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    status text,
    deliveryresult jsonb,
    deliverysignature jsonb,
    log jsonb
)


/************************************************************
*
* Function:  send_email_by_messageid
* 
* send an message from the messagess table 
*
************************************************************/
create or replace function public.send_email_by_messageid(messageid text)
   returns text 
   language plpgsql
   SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
  -- SET search_path = admin, pg_temp;
  as
$$
declare 
-- variable declaration
sender text;
recipient text;
subject text;
text_body text;
html_body text;
cc text;
bcc text;
status text;
retval text;
MAILGUN_DOMAIN text;
MAILGUN_API_KEY text;
begin
  -- logic
  -- check for valid invitation for current user by email
  -- select auth.email into current_user_email;
  select  messages.sender,
          messages.recipient, 
          messages.cc,
          messages.bcc,
          messages.subject, 
          messages.text_body, 
          messages.html_body, 
          messages.status 
    into  sender,
          recipient, 
          cc,
          bcc,
          subject, 
          text_body, 
          html_body, 
          status 
    from public.messages 
   where  id = messageid::uuid;
  if not found then
     raise 'invalid messageid';
  elsif status <> 'ready' then
    raise 'invalid message status: %', status;
  else
  
    select value::text into MAILGUN_DOMAIN from private.keys where key = 'MAILGUN_DOMAIN';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_DOMAIN';
    end if;

    -- select value::text into MAILGUN_URL_MESSAGES from private.keys where key = 'MAILGUN_URL_MESSAGES';
    select value::text into MAILGUN_API_KEY from private.keys where key = 'MAILGUN_API_KEY';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_API_KEY';
    end if;

    SELECT content into retval FROM http(
      (
        'POST',
        'https://api.mailgun.net/v3/' || MAILGUN_DOMAIN || '/messages',
        ARRAY[http_header('Authorization','Basic ' || encode(MAILGUN_API_KEY::bytea,'base64'::text))],
        'application/x-www-form-urlencoded',        
        'from=' || urlencode(sender) || 
        '&to=' || urlencode(recipient) ||
        case when cc is not null then '&cc=' || urlencode(cc) else '' end ||
        case when bcc is not null then '&bcc=' || urlencode(bcc) else '' end ||
        '&v:messageid=' || urlencode(messageid) || 
        '&subject=' || urlencode(subject) || 
        '&text=' || urlencode(text_body) || 
        '&html=' || urlencode(html_body)
      )
    );
    /* the following line needs to parse retval for the actual returned status */
    update public.messages set status = 'queued',
           deliveryresult = retval::jsonb,
           log = COALESCE(log, '[]'::jsonb) || retval::jsonb
           where id = messageid::uuid; 
    return retval;
  
  end if;
end;
$$
/************************************************************
*
* Function:  mailgun_webhook
* 
* Mailgun web hook
* Paste the URL below into all of the MailGun WebHook entries
* https://<database_url>.supabase.co/rest/v1/rpc/mailgun_webhook?apikey=<public_api_key>
*
************************************************************/
create or replace function public.mailgun_webhook("event-data" jsonb, "signature" jsonb)
   returns text 
   language plpgsql
   SECURITY DEFINER
   -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
   -- SET search_path = admin, pg_temp;
  as
$$
declare
messageid text;
begin
  select "event-data"->'user-variables'->>'messageid'::text into messageid;

  update public.messages 
    set 
        deliverysignature = signature,
        deliveryresult = "event-data",
        status = "event-data"->>'event'::text,
        log = COALESCE(log, '[]'::jsonb) || "event-data"-->'event'

    where  messages.id = messageid::uuid;

  return 'ok';    
end;
$$
/************************************************************/
/************************************************************
*
* Function:  create_message(message JSON)
* 
* create a message in the messages table
*
{
  recipient: "", -- REQUIRED 
  sender: "", -- REQUIRED 
  cc: "",
  bcc: "",
  subject: "", -- REQUIRED 
  text_body: "", -- REQUIRED  
  html_body: ""
}
returns:  uuid (as text) of newly inserted message
************************************************************/
create or replace function public.create_message(message JSON)
   returns text
   language plpgsql
   SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
  -- SET search_path = admin, pg_temp;
  as
$$
declare 
-- variable declaration
recipient text;
sender text;
cc text;
bcc text;
subject text;
text_body text;
html_body text;
retval text;
begin
  /*
  if not exists (message->>'recipient') then
    RAISE INFO 'messages.recipient missing';
  end if
  */
  select  message->>'recipient', 
          message->>'sender',
          message->>'cc',
          message->>'bcc',
          message->>'subject',
          message->>'text_body',
          message->>'html_body' into recipient, sender, cc, bcc, subject, text_body, html_body;
  
  if coalesce(sender, '') = '' then
    -- select 'no sender' into retval;
    RAISE EXCEPTION 'message.sender missing';
  elseif coalesce(recipient, '') = '' then
    RAISE EXCEPTION 'message.recipient missing';
  elseif coalesce(subject, '') = '' then
    RAISE EXCEPTION 'message.subject missing';
  elseif coalesce(text_body, '') = '' and coalesce(html_body, '') = '' then
    RAISE EXCEPTION 'message.text_body and message.html_body are both missing';
  end if;

  if coalesce(text_body, '') = '' then
    select html_body into text_body;
  elseif coalesce(html_body, '') = '' then
    select text_body into html_body;
  end if; 

  insert into public.messages(recipient, sender, cc, bcc, subject, text_body, html_body, status, log)
  values (recipient, sender, cc, bcc, subject, text_body, html_body, 'ready', '[]'::jsonb) returning id into retval;

  return retval;
end;
$$
/*
  id uuid primary key default uuid_generate_v4(),
  recipient text,
  sender text,
  cc text,
  bcc text,
  subject text,
  text_body text,
  html_body text,
  created timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
  status text,
  deliveryresult jsonb,
  deliverysignature jsonb,
  log jsonb
*/
/************************************************************
*
* Function:  send_message(message JSON)
* 
* create a message in the messages table
*
{
  recipient: "", -- REQUIRED 
  sender: "", -- REQUIRED 
  cc: "",
  bcc: "",
  subject: "", -- REQUIRED 
  text_body: "", -- REQUIRED  
  html_body: ""
}
returns:  result as text
************************************************************/
create or replace function public.send_message(message JSON)
   returns text
   language plpgsql
   SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
  -- SET search_path = admin, pg_temp;
  as
$$
declare 
-- variable declaration
messageid text;
retval text;
begin
  select public.create_message(message) into messageid;

  select public.send_email_by_messageid(messageid) into retval;
  
  return retval;
end;
$$


/*
webhooks:
clicked
complained
delivered
opened
permanent_fail
temporary_fail
unsubscribed

get webhooks
curl -s --user "api:key-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" "https://api.mailgun.net/v3/domains/MY_DOMAIN/webhooks"

create webhook
curl -s --user 'api:YOUR_API_KEY' \
   https://api.mailgun.net/v3/domains/YOUR_DOMAIN_NAME/webhooks \
   -F id='clicked' \
   -F url='https://YOUR_SUPABASE_URL/rest/v1/rpc/mailgun_webhook?apikey=YOUR_PUBLIC_SUPABASE_KEY'

update webhook
curl -s --user 'api:YOUR_API_KEY' -X PUT \
    https://api.mailgun.net/v3/domains/YOUR_DOMAIN_NAME/webhooks/clicked \
    -F url='https://your_domain,com/v1/clicked'

delete webhook
curl -s --user 'api:YOUR_API_KEY' -X DELETE \
    https://api.mailgun.net/v3/domains/YOUR_DOMAIN_NAME/webhooks/clicked

*/

/************************************************************
*
* Function:  create_mailgun_webhook
* 
* create, replace, or delete a single mailgun webook 
*
************************************************************/
create or replace function public.create_mailgun_webhook("hook_name" text, "mode" text)
   returns text 
   language plpgsql
   SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
  -- SET search_path = admin, pg_temp;
  as
$$
declare 
-- variable declaration
retval text;
MAILGUN_DOMAIN text;
MAILGUN_API_KEY text;
webhooks jsonb;
MAILGUN_WEBHOOK_URL text;
begin
    select value::text into MAILGUN_WEBHOOK_URL from private.keys where key = 'MAILGUN_WEBHOOK_URL';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_WEBHOOK_URL';
    end if;
    select value::text into MAILGUN_DOMAIN from private.keys where key = 'MAILGUN_DOMAIN';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_DOMAIN';
    end if;
    select value::text into MAILGUN_API_KEY from private.keys where key = 'MAILGUN_API_KEY';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_API_KEY';
    end if;

    if mode = 'CREATE' then
      SELECT content into retval FROM http(
        (
          'POST',
          'https://api.mailgun.net/v3/domains/' || MAILGUN_DOMAIN || '/webhooks',
          ARRAY[http_header('Authorization','Basic ' || encode(MAILGUN_API_KEY::bytea,'base64'::text))],
          'application/x-www-form-urlencoded',        
          'id=' ||  urlencode(hook_name) ||
          '&url=' || urlencode(MAILGUN_WEBHOOK_URL)
        )
      );
    elseif mode = 'UPDATE' then
      SELECT content into retval FROM http(
        (
          'PUT',
          'https://api.mailgun.net/v3/domains/' || MAILGUN_DOMAIN || '/webhooks/' || hook_name,
          ARRAY[http_header('Authorization','Basic ' || encode(MAILGUN_API_KEY::bytea,'base64'::text))],
          'application/x-www-form-urlencoded',        
          'url=' || urlencode(MAILGUN_WEBHOOK_URL)
        )
      );
    elseif mode = 'DELETE' then
      SELECT content into retval FROM http(
        (
          'DELETE',
          'https://api.mailgun.net/v3/domains/' || MAILGUN_DOMAIN || '/webhooks/' || hook_name,
          ARRAY[http_header('Authorization','Basic ' || encode(MAILGUN_API_KEY::bytea,'base64'::text))],
          'application/x-www-form-urlencoded',        
          'url=' || urlencode(MAILGUN_WEBHOOK_URL)
        )
      );
    else
      raise 'unknown mode: %', mode;
    end if;

    return retval;
end;
$$

/************************************************************
*
* Function:  setup_mailgun_webhooks
* 
* create or replace ALL mailgun webooks
*
************************************************************/
create or replace function public.setup_mailgun_webhooks()
   returns text 
   language plpgsql
   SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
  -- SET search_path = admin, pg_temp;
  as
$$
declare 
-- variable declaration
MAILGUN_DOMAIN text;
MAILGUN_API_KEY text;
webhooks jsonb;
MAILGUN_WEBHOOK_URL text;
hook_result text;
retval text;
begin
    select value::text into MAILGUN_WEBHOOK_URL from private.keys where key = 'MAILGUN_WEBHOOK_URL';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_WEBHOOK_URL';
    end if;
    select value::text into MAILGUN_DOMAIN from private.keys where key = 'MAILGUN_DOMAIN';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_DOMAIN';
    end if;
    select value::text into MAILGUN_API_KEY from private.keys where key = 'MAILGUN_API_KEY';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_API_KEY';
    end if;
    SELECT content into webhooks FROM http(
      (
        'GET',
        -- replace(MAILGUN_URL_MESSAGES, '/messages', '/webhooks'),
        'https://api.mailgun.net/v3/domains/' || MAILGUN_DOMAIN || '/webhooks',
        ARRAY[http_header('Authorization','Basic ' || encode(MAILGUN_API_KEY::bytea,'base64'::text))],
        'application/x-www-form-urlencoded',
        ''
      )
    );

    select '[' into retval;

    if length(webhooks->'webhooks'->>'clicked') > 0 then
      select public.create_mailgun_webhook('clicked', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('clicked', 'CREATE') into hook_result;
    end if;

    select retval || '{ "clicked": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;

    if length(webhooks->'webhooks'->>'complained') > 0 then
      select public.create_mailgun_webhook('complained', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('complained', 'CREATE') into hook_result;
    end if;

    select retval || ', { "complained": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;

    if length(webhooks->'webhooks'->>'delivered') > 0 then
      select public.create_mailgun_webhook('delivered', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('delivered', 'CREATE') into hook_result;
    end if;

    select retval || ', { "delivered": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;

    if length(webhooks->'webhooks'->>'opened') > 0 then
      select public.create_mailgun_webhook('opened', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('opened', 'CREATE') into hook_result;
    end if;

    select retval || ', { "opened": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;

    if length(webhooks->'webhooks'->>'permanent_fail') > 0 then
      select public.create_mailgun_webhook('permanent_fail', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('permanent_fail', 'CREATE') into hook_result;
    end if;

    select retval || ', { "permanent_fail": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;

    if length(webhooks->'webhooks'->>'temporary_fail') > 0 then
      select public.create_mailgun_webhook('temporary_fail', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('temporary_fail', 'CREATE') into hook_result;
    end if;

    select retval || ', { "temporary_fail": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;

    if length(webhooks->'webhooks'->>'unsubscribed') > 0 then
      select public.create_mailgun_webhook('unsubscribed', 'UPDATE') into hook_result;
    else
      select public.create_mailgun_webhook('unsubscribed', 'CREATE') into hook_result;
    end if;

    select retval || ', { "unsubscribed": "' || (hook_result::jsonb->>'message'::text) || '" } ' into retval::text;
    
    select retval || ']' into retval;

    return retval::jsonb;
  
end;
$$

/************************************************************
*
* Function:  get_current_mailgun_webhooks
* 
* list the status of all mailgun webhooks
*
************************************************************/

create or replace function public.get_current_mailgun_webhooks()
   returns jsonb 
   language plpgsql
   SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.  abort 
  -- SET search_path = admin, pg_temp;
  as
$$
declare 
-- variable declaration
MAILGUN_DOMAIN text;
MAILGUN_API_KEY text;
retval jsonb;
begin

    select value::text into MAILGUN_DOMAIN from private.keys where key = 'MAILGUN_DOMAIN';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_DOMAIN';
    end if;
    select value::text into MAILGUN_API_KEY from private.keys where key = 'MAILGUN_API_KEY';
    if not found then
      raise 'missing entry in private.keys: MAILGUN_API_KEY';
    end if;
    SELECT content into retval FROM http(
      (
        'GET',
        -- replace(MAILGUN_URL_MESSAGES, '/messages', '/webhooks'),
        'https://api.mailgun.net/v3/domains/' || MAILGUN_DOMAIN || '/webhooks',
        ARRAY[http_header('Authorization','Basic ' || encode(MAILGUN_API_KEY::bytea,'base64'::text))],
        'application/x-www-form-urlencoded',
        ''
      )
    );


    return retval::jsonb;
  
end;
$$
