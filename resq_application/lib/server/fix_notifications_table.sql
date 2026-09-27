-- Fix notifications table to remove foreign key constraint and allow NULL recipient_ID
-- This will fix the notification POST failures

-- Drop the foreign key constraint if it exists
ALTER TABLE notifications DROP FOREIGN KEY IF EXISTS notifications_ibfk_1;

-- Make recipient_ID nullable (if not already)
ALTER TABLE notifications MODIFY recipient_ID INT NULL;