-- Step 1, part 5: built-in recipe library (household_id null, source 'seed').
-- Line: title|servings|minutes|steps|ingredient:qty:unit,...  (a trailing ? on the id marks it optional)

create temp table _rec_raw (l text) on commit drop;
insert into _rec_raw
select l from unnest(string_to_array($data$
Pollo al ajillo|4|40|Brown chicken with salt and pepper. Add sliced garlic and bay leaf, pour in white wine, cover and cook 25 min.|chicken_thigh:800:g,garlic:6:unit,white_wine:100:ml,olive_oil:50:ml,bay_leaf:1:unit,parsley:10:g?,salt:1:g,pepper:1:g
Lentejas estofadas|4|50|Sauté onion, carrot and pepper, add paprika, lentils and water. Simmer 35 min.|lentils:300:g,onion:1:unit,carrot:2:unit,bell_pepper_green:1:unit,garlic:2:unit,paprika:5:g,bay_leaf:1:unit,olive_oil:30:ml,chorizo:100:g?
Garbanzos con espinacas|4|40|Fry garlic and cumin, add spinach and chickpeas, simmer 15 min.|canned_chickpeas:800:g,spinach:400:g,garlic:3:unit,cumin:3:g,paprika:3:g,olive_oil:40:ml,vinegar:10:ml
Tortilla de patata|4|35|Fry sliced potato and onion slowly. Mix with beaten eggs, cook in a pan flipping once.|potato:600:g,onion:1:unit,eggs:6:unit,olive_oil:150:ml,salt:1:g
Arroz con pollo|4|45|Brown chicken, add pepper and tomato, stir in rice and stock, cook 18 min.|rice:300:g,chicken_thigh:600:g,tomato:2:unit,bell_pepper_red:1:unit,stock:900:ml,garlic:2:unit,paprika:5:g,peas:100:g?
Paella de verduras|4|45|Sauté vegetables, add rice, saffron and stock, cook 18 min without stirring.|rice:320:g,green_beans:200:g,bell_pepper_red:1:unit,tomato:2:unit,stock:900:ml,saffron:1:g,olive_oil:50:ml,artichoke:4:unit?
Espaguetis a la boloñesa|4|45|Fry onion and carrot, add minced beef and tomato, simmer 30 min. Serve over spaghetti.|pasta_spaghetti:400:g,minced_beef:400:g,onion:1:unit,carrot:1:unit,tomato_sauce:400:g,garlic:2:unit,olive_oil:30:ml,cheese_parmesan:30:g?
Macarrones con tomate|4|25|Boil pasta. Warm tomato sauce with garlic and mix.|pasta_penne:400:g,tomato_sauce:400:g,garlic:1:unit,olive_oil:20:ml,cheese_grated:50:g?
Pasta al pesto|4|20|Boil pasta, toss with pesto and cherry tomatoes.|pasta_penne:400:g,pesto:150:g,cherry_tomato:200:g,cheese_parmesan:30:g?,pine_nuts:20:g?
Lasaña de carne|6|75|Layer sheets with meat sauce and cheese, bake 35 min at 180 C.|lasagne_sheets:250:g,minced_beef:500:g,tomato_sauce:500:g,onion:1:unit,milk:500:ml,flour:40:g,butter:40:g,cheese_grated:150:g
Macarrones carbonara|4|25|Fry bacon. Mix eggs, cheese and pepper, toss with hot pasta off the heat.|pasta_penne:400:g,bacon:150:g,eggs:3:unit,cheese_parmesan:60:g,pepper:1:g,cream:100:ml?
Sopa de pollo con fideos|4|40|Simmer chicken, carrot and leek in water. Add noodles for the last 5 min.|chicken_breast:300:g,noodles:100:g,carrot:2:unit,leek:1:unit,celery:1:unit?,salt:2:g
Crema de calabacín|4|30|Cook onion, courgette and potato in stock, blend smooth.|courgette:600:g,potato:200:g,onion:1:unit,stock:600:ml,olive_oil:20:ml,cream:50:ml?
Crema de calabaza|4|35|Roast or simmer pumpkin with onion and carrot, blend with stock.|pumpkin:700:g,onion:1:unit,carrot:1:unit,stock:600:ml,olive_oil:20:ml,nutmeg:1:g?
Gazpacho casero|4|15|Blend tomato, cucumber, pepper, garlic, oil and vinegar. Chill.|tomato:1000:g,cucumber:1:unit,bell_pepper_green:1:unit,garlic:1:unit,olive_oil:60:ml,vinegar:20:ml,salt:3:g
Ensalada mixta|2|10|Combine lettuce, tomato, onion and tuna. Dress with oil and vinegar.|lettuce:1:unit,tomato:2:unit,onion:1:unit,tuna_canned:120:g,olives:50:g?,olive_oil:30:ml,vinegar:10:ml
Ensalada de garbanzos|2|10|Mix drained chickpeas with tomato, cucumber and onion. Dress.|canned_chickpeas:400:g,tomato:1:unit,cucumber:1:unit,red_onion:1:unit,olive_oil:30:ml,vinegar:10:ml,parsley:5:g?
Ensalada de pasta|4|20|Boil pasta, cool, mix with tuna, corn and tomato.|pasta_penne:300:g,tuna_canned:160:g,canned_corn:150:g,tomato:2:unit,mayonnaise:60:g?,olive_oil:20:ml
Huevos rotos con jamón|2|25|Fry potatoes, top with fried eggs and ham, break the yolks.|potato:500:g,eggs:4:unit,serrano_ham:80:g,olive_oil:100:ml
Revuelto de espárragos|2|15|Sauté asparagus and garlic, add beaten eggs and scramble.|asparagus:250:g,eggs:4:unit,garlic:1:unit,olive_oil:20:ml
Merluza al horno|2|30|Bake hake over sliced potato and onion with oil and lemon at 200 C.|hake:400:g,potato:300:g,onion:1:unit,lemon:1:unit,olive_oil:30:ml,parsley:5:g?
Salmón al horno con verduras|2|30|Roast salmon with courgette and pepper 15 min at 200 C.|salmon:300:g,courgette:1:unit,bell_pepper_red:1:unit,olive_oil:20:ml,lemon:1:unit
Bacalao con tomate|4|40|Simmer tomato sauce with pepper, add cod and cook 10 min.|cod:600:g,tomato_sauce:400:g,bell_pepper_red:1:unit,onion:1:unit,garlic:2:unit,olive_oil:30:ml
Gambas al ajillo|2|15|Warm garlic and chilli in oil, add prawns, cook 3 min.|prawns:300:g,garlic:4:unit,chilli:1:unit,olive_oil:80:ml,parsley:5:g?
Calamares a la romana|4|25|Coat squid rings in flour and egg, fry until golden.|squid:500:g,flour:100:g,eggs:2:unit,sunflower_oil:300:ml,lemon:1:unit
Mejillones al vapor|2|15|Steam mussels with white wine, garlic and lemon until open.|mussels:1000:g,white_wine:100:ml,garlic:2:unit,lemon:1:unit,parsley:5:g?
Albóndigas en salsa|4|50|Shape meatballs, brown, simmer in tomato and onion sauce 25 min.|minced_beef:500:g,minced_pork:250:g,eggs:1:unit,breadcrumbs:50:g,tomato_sauce:400:g,onion:1:unit,garlic:2:unit,parsley:5:g
Filetes de pollo empanados|4|25|Dip chicken in egg and breadcrumbs, fry until golden.|chicken_breast:600:g,eggs:2:unit,breadcrumbs:100:g,flour:50:g,sunflower_oil:200:ml,lemon:1:unit?
Pollo asado con patatas|4|75|Roast chicken on potato and onion at 190 C for 70 min.|whole_chicken:1500:g,potato:800:g,onion:1:unit,garlic:3:unit,olive_oil:40:ml,paprika:5:g
Ternera estofada|4|120|Brown beef, add onion, carrot, wine and stock, simmer 90 min.|beef_stew:800:g,onion:1:unit,carrot:2:unit,red_wine:200:ml,stock:400:ml,flour:20:g,bay_leaf:1:unit,potato:300:g?
Lomo con pimientos|4|35|Pan-fry pork loin, serve with sautéed peppers.|pork_loin:600:g,bell_pepper_green:2:unit,bell_pepper_red:1:unit,garlic:2:unit,olive_oil:40:ml
Costillas al horno|4|90|Marinate ribs with paprika and honey, bake 80 min at 170 C.|pork_ribs:1200:g,honey:30:g,smoked_paprika:5:g,garlic:3:unit,soy_sauce:30:ml
Cordero asado|4|100|Roast lamb with potato, garlic and rosemary at 180 C.|lamb:1200:g,potato:600:g,garlic:4:unit,rosemary:5:g,white_wine:100:ml,olive_oil:30:ml
Judías verdes con jamón|4|25|Boil green beans and potato, sauté with garlic and ham.|green_beans:500:g,potato:300:g,serrano_ham:80:g,garlic:2:unit,olive_oil:30:ml
Menestra de verduras|4|35|Cook artichoke, peas, carrot and beans with ham and a little stock.|artichoke:4:unit,peas:200:g,carrot:2:unit,green_beans:200:g,serrano_ham:60:g,onion:1:unit,olive_oil:30:ml
Verduras al horno|4|45|Roast sliced vegetables with oil and salt at 200 C for 35 min.|courgette:1:unit,aubergine:1:unit,bell_pepper_red:1:unit,onion:1:unit,potato:300:g,olive_oil:50:ml,thyme:2:g?
Berenjenas con miel|2|25|Slice aubergine, fry or roast, drizzle with honey.|aubergine:2:unit,flour:50:g,sunflower_oil:200:ml,honey:30:g
Champiñones al ajillo|2|15|Sauté mushrooms with garlic and parsley.|mushrooms:400:g,garlic:3:unit,olive_oil:30:ml,parsley:5:g,white_wine:50:ml?
Coliflor gratinada|4|40|Boil cauliflower, cover with white sauce and cheese, bake until golden.|cauliflower:1:unit,milk:500:ml,flour:40:g,butter:40:g,cheese_grated:100:g,nutmeg:1:g?
Brócoli salteado|2|15|Steam broccoli, sauté with garlic and chilli.|broccoli:400:g,garlic:2:unit,olive_oil:30:ml,chilli:1:unit?,lemon:1:unit?
Curry de garbanzos|4|35|Fry onion, ginger and curry, add tomato, coconut milk and chickpeas, simmer 20 min.|canned_chickpeas:800:g,coconut_milk:400:ml,onion:1:unit,tomato_crushed:400:g,garlic:2:unit,ginger:10:g,curry:10:g,spinach:100:g?,rice:300:g?
Curry de pollo|4|40|Brown chicken with onion and curry, add coconut milk, simmer 20 min.|chicken_breast:600:g,coconut_milk:400:ml,onion:1:unit,garlic:2:unit,ginger:10:g,curry:10:g,rice:300:g
Arroz con tomate y huevo|2|20|Boil rice, serve with tomato sauce and a fried egg.|rice:200:g,tomato_sauce:200:g,eggs:2:unit,olive_oil:20:ml
Arroz tres delicias|4|25|Fry cooked rice with peas, carrot, ham and egg.|rice:300:g,peas:100:g,carrot:1:unit,cooked_ham:100:g,eggs:2:unit,soy_sauce:30:ml
Fideuà|4|45|Toast noodles, add squid, prawns and stock, bake or simmer 12 min.|noodles:300:g,prawns:200:g,squid:200:g,tomato_sauce:100:g,stock:700:ml,garlic:2:unit,olive_oil:40:ml
Cuscús con verduras|2|20|Pour hot stock over couscous. Stir in sautéed vegetables.|couscous:200:g,stock:250:ml,courgette:1:unit,bell_pepper_red:1:unit,onion:1:unit,olive_oil:20:ml,raisins:30:g?
Bocadillo de tortilla|2|5|Fill bread with potato omelette.|bread:1:unit,tortilla_prepared:300:g,tomato:1:unit?
Tostadas con tomate y jamón|2|10|Toast bread, rub with tomato, top with oil and ham.|bread:1:unit,tomato:2:unit,serrano_ham:60:g,olive_oil:20:ml
Tostadas con aguacate|2|10|Toast bread, mash avocado with lemon and salt, spread and top with egg.|bread:1:unit,avocado:2:unit,lemon:1:unit,eggs:2:unit?,salt:1:g
Pizza casera|4|40|Spread sauce on dough, add cheese and toppings, bake 15 min at 220 C.|pizza_dough:1:unit,tomato_sauce:200:g,cheese_mozzarella:250:g,cooked_ham:100:g?,mushrooms:100:g?,oregano:2:g?
Quesadillas|2|15|Fill wraps with cheese and ham, brown on both sides.|tortilla_wraps:4:unit,cheese_grated:150:g,cooked_ham:80:g,bell_pepper_red:1:unit?
Sándwich mixto|2|10|Layer ham and cheese between bread, toast.|sliced_bread:4:unit,cooked_ham:4:unit,cheese_sliced:4:unit,butter:10:g
Hummus casero|4|10|Blend chickpeas with sesame, lemon, garlic and oil.|canned_chickpeas:400:g,sesame:30:g,lemon:1:unit,garlic:1:unit,olive_oil:40:ml,cumin:2:g?
Porridge de avena|1|10|Simmer oats in milk, top with fruit and honey.|oats:50:g,milk:250:ml,banana:1:unit,honey:10:g?,cinnamon:1:g?
Yogur con fruta y miel|1|5|Top yogurt with chopped fruit, nuts and honey.|yogurt_greek:250:g,strawberry:100:g?,blueberry:50:g?,honey:10:g,walnuts:20:g?
Batido de plátano|2|5|Blend banana with milk.|banana:2:unit,milk:400:ml,cocoa_powder:10:g?
Tortitas de plátano|2|15|Mash banana, mix with eggs and oats, cook small pancakes.|banana:2:unit,eggs:2:unit,oats:60:g,butter:10:g
Bizcocho de yogur|8|50|Mix yogurt, oil, sugar, eggs and flour. Bake 40 min at 180 C.|yogurt_plain:125:g,sugar:250:g,sunflower_oil:120:ml,eggs:3:unit,flour:250:g,baking_powder:16:g,lemon:1:unit?
Arroz con leche|6|50|Simmer rice in milk with cinnamon and lemon peel, add sugar.|rice:150:g,milk:1500:ml,sugar:120:g,cinnamon:2:g,lemon:1:unit
Natillas|4|25|Heat milk, whisk with yolks, sugar and flour, thicken.|milk:500:ml,eggs:4:unit,sugar:100:g,flour:20:g,vanilla:2:g?
Torrijas|4|30|Soak bread in milk, dip in egg, fry, dust with sugar and cinnamon.|bread:1:unit,milk:500:ml,eggs:2:unit,sugar:80:g,cinnamon:3:g,sunflower_oil:200:ml
Patatas bravas|4|35|Fry or roast potato wedges, serve with spicy tomato sauce.|potato:800:g,tomato_sauce:200:g,smoked_paprika:5:g,chilli_flakes:1:g,sunflower_oil:300:ml
Croquetas de jamón|6|60|Make a thick white sauce with ham, chill, shape, coat and fry.|cooked_ham:150:g,milk:600:ml,flour:80:g,butter:60:g,eggs:2:unit,breadcrumbs:100:g,sunflower_oil:300:ml
$data$, E'\n')) as l where l <> '';

create temp table _rec_ids on commit drop as
select gen_random_uuid() as id, split_part(l, '|', 1) as title, l from _rec_raw;

insert into public.recipes (id, household_id, title, servings, minutes, steps, source)
select id, null, title, split_part(l, '|', 2)::int, split_part(l, '|', 3)::int, split_part(l, '|', 4), 'seed'
from _rec_ids;

insert into public.recipe_ingredients (recipe_id, ingredient_id, quantity, unit, optional)
select r.id,
       replace(split_part(i, ':', 1), '?', ''),
       split_part(i, ':', 2)::numeric,
       replace(split_part(i, ':', 3), '?', ''),
       i like '%?'
from _rec_ids r, lateral unnest(string_to_array(split_part(r.l, '|', 5), ',')) as i;
