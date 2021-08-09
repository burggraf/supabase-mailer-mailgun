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
