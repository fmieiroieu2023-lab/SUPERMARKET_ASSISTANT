-- Step 1, part 8: deleting a household must delete everything in it (needed for account deletion in step 11).
-- Found while cleaning up test data: the purchase line -> product foreign key was checked before the purchase lines
-- themselves were removed. Deferring the check to the end of the transaction keeps "a product with history can't be
-- deleted" but lets a whole household go in one delete.
alter table public.purchase_items alter constraint purchase_items_product_id_household_id_fkey deferrable initially deferred;
alter table public.pantry_lots    alter constraint pantry_lots_purchase_item_id_household_id_fkey deferrable initially deferred;
