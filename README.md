# supabase-mailer-mailgun
Send email from Supabase / PostgreSQL using Mailgun

## Features
- Function to create outgoing email messages in a PostgreSQL table
- Function to send a `message` from the `messages` table using Mailgun
- Function to setup Mailgun Webooks that will automatically track your messages and update your `messages` table:
  - delivered
  - opened
  - clicked
  - complained
  - permanent_fail
  - temporary_fail
  - unsubscribed

## Requirements
- Supabase account (free tier is fine)
  - Sending messages should work with any PostgreSQL database (no Supabase account required)
  - Webhooks require a Supabase account so the webhooks have a server to post event messages to
- Mailgun account (free tier is fine)
