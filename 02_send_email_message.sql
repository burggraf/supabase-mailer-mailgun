/************************************************************
 *
 * Function:  send_email_message
 * 
 * low level function to send email message
 *
 ************************************************************/
CREATE OR REPLACE FUNCTION public.send_email_message (message json)
  RETURNS json
  LANGUAGE plpgsql
  SECURITY DEFINER
  -- Set a secure search_path: trusted schema(s), then 'pg_temp'.
  -- SET search_path = admin, pg_temp;
  AS $$
DECLARE
  -- variable declaration
  sender text;
  recipient text;
  subject text;
  text_body text;
  html_body text;
  cc text;
  bcc text;
  messageid text;
  status text;
  retval json;
  MAILGUN_DOMAIN text;
  MAILGUN_API_KEY text;
BEGIN
  IF message ->> 'messageid' IS NOT NULL THEN    
    -- messageid was sent, get this message from the messages table
    SELECT
      messages.sender,
      messages.recipient,
      messages.cc,
      messages.bcc,
      messages.subject,
      messages.text_body,
      messages.html_body,
      messages.status,
      messages.id::text AS messageid INTO sender,
      recipient,
      cc,
      bcc,
      subject,
      text_body,
      html_body,
      status,
      messageid
    FROM
      public.messages
    WHERE
      id = (message ->> 'messageid')::uuid;
    IF NOT found THEN
      RAISE 'invalid messageid';
    elsif status <> 'ready' THEN
      RAISE 'invalid message status: % (message status must be: ''ready'')', status;
    END IF;
  ELSE
    -- no messageid was sent, create a new message
    SELECT
      message ->> 'recipient',
      message ->> 'sender',
      message ->> 'cc',
      message ->> 'bcc',
      message ->> 'subject',
      message ->> 'text_body',
      message ->> 'html_body',
      'ready' INTO recipient,
      sender,
      cc,
      bcc,
      subject,
      text_body,
      html_body,
      status;
  END IF;
  IF coalesce(text_body, '') = '' THEN
    SELECT
      html_body INTO text_body;
    elseif coalesce(html_body, '') = '' THEN
      SELECT
        text_body INTO html_body;
  END IF;
  IF recipient IS NULL THEN
    RAISE 'messages.recipient is required';
  END IF;
  IF sender IS NULL THEN
    RAISE 'messages.sender is required';
  END IF;
  IF subject IS NULL THEN
    RAISE 'messages.subject is required';
  END IF;
  IF text_body IS NULL THEN
    RAISE 'messages.text_body is required';
  END IF;
  SELECT
    value::text INTO MAILGUN_DOMAIN
  FROM
    private.keys
  WHERE
    key = 'MAILGUN_DOMAIN';
  IF NOT found THEN
    RAISE 'missing entry in private.keys: MAILGUN_DOMAIN';
  END IF;
  SELECT
    value::text INTO MAILGUN_API_KEY
  FROM
    private.keys
  WHERE
    key = 'MAILGUN_API_KEY';
  IF NOT found THEN
    RAISE 'missing entry in private.keys: MAILGUN_API_KEY';
  END IF;

  IF messageid IS NULL AND (SELECT to_regclass('public.messages')) IS NOT NULL THEN
    -- messages table exists, so save this message in the messages table
    INSERT INTO public.messages(recipient, sender, cc, bcc, subject, text_body, html_body, status, log)
    VALUES (recipient, sender, cc, bcc, subject, text_body, html_body, 'ready', '[]'::jsonb) RETURNING id INTO messageid;        
  END IF;

  SELECT
    content INTO retval
  FROM
    http (('POST', 
      'https://api.mailgun.net/v3/' || MAILGUN_DOMAIN || '/messages', 
      ARRAY[http_header ('Authorization', 
      'Basic ' || encode(MAILGUN_API_KEY::bytea, 'base64'::text))], 
      'application/x-www-form-urlencoded', 
      'from=' || urlencode (sender) || 
      '&to=' || urlencode (recipient) || 
      CASE WHEN cc IS NOT NULL THEN '&cc=' || urlencode (cc) ELSE '' END || 
      CASE WHEN bcc IS NOT NULL THEN '&bcc=' || urlencode (bcc) ELSE '' END || 
      CASE WHEN messageid IS NOT NULL THEN '&v:messageid=' || urlencode (messageid) ELSE '' END || 
      '&subject=' || urlencode (subject) || 
      '&text=' || urlencode (text_body) || 
      '&html=' || urlencode (html_body)));
  
  -- if the message table exists, 
  -- and the response from the mail server contains an id
  -- and the message from the mail server starts wtih 'Queued'
  -- mark this message as 'queued' in our message table, otherwise leave it as 'ready'
  IF  (SELECT to_regclass('public.messages')) IS NOT NULL AND 
      retval->'id' IS NOT NULL 
      AND substring(retval->>'message',1,6) = 'Queued' THEN
    UPDATE public.messages SET status = 'queued' WHERE id = messageid::UUID;
  END IF;
  RETURN retval;
END;
$$
