-- 0013: staff can add items / mark sold-out / add categories, and add / rename / remove tables.
-- Still OWNER-only: deleting items or categories, renaming categories, tax + bill settings, "New QR", analytics.
-- Safe to re-run.
do $$ declare p text; begin
  foreach p in array array['cafe_categories_i','cafe_items_i','cafe_items_u','cafe_tables_i','cafe_tables_u','cafe_tables_d'] loop
    execute format('drop policy if exists %I on %I', p, substr(p, 1, length(p) - 2));
  end loop;
end $$;

create policy cafe_categories_i on cafe_categories for insert with check (shop_id = current_shop_id() and cafe_can_write(shop_id));
create policy cafe_items_i on cafe_items for insert with check (shop_id = current_shop_id() and cafe_can_write(shop_id));
create policy cafe_items_u on cafe_items for update using (shop_id = current_shop_id() and cafe_can_write(shop_id)) with check (shop_id = current_shop_id());
create policy cafe_tables_i on cafe_tables for insert with check (shop_id = current_shop_id() and cafe_can_write(shop_id));
create policy cafe_tables_u on cafe_tables for update using (shop_id = current_shop_id() and cafe_can_write(shop_id)) with check (shop_id = current_shop_id());
create policy cafe_tables_d on cafe_tables for delete using (shop_id = current_shop_id() and cafe_can_write(shop_id));

-- Menu photos: staff may upload too
drop policy if exists "cafe-menu insert" on storage.objects;
create policy "cafe-menu insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'cafe-menu' and (storage.foldername(name))[1] = current_shop_id()::text and cafe_can_write(current_shop_id()));