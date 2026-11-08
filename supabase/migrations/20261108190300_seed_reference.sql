-- Step 1, part 4: reference data (global, read-only to users).
-- Ingredient lines: id | name_es | name_en | typical_unit_g | is_basic | aliases (; separated).
-- Aliases are Spanish receipt abbreviations (upper-case, no accents) and Open Food Facts tags (en:...).

insert into public.chains (id, name) values
  ('mercadona', 'Mercadona'), ('carrefour', 'Carrefour'), ('supercor', 'Supercor'), ('other', 'Otro');

-- Categories: id, name, is_food, location, shelf_life, opened_life, freezer_life, expiry_kind, ask_printed_date, grace_days
insert into public.categories
  (id, name_es, is_food, default_location, shelf_life_days, opened_shelf_life_days, freezer_life_days, expiry_kind, ask_printed_date, check_grace_days) values
  ('fresh_meat',       'Carne fresca',                    true,  'fridge',  3,   null, 180,  'use_by',      true,  null),
  ('fresh_poultry',    'Pollo y aves',                    true,  'fridge',  3,   null, 270,  'use_by',      true,  null),
  ('fresh_fish',       'Pescado y marisco fresco',        true,  'fridge',  2,   null, 90,   'use_by',      true,  null),
  ('cured_meat',       'Embutidos y jamón',               true,  'fridge',  21,  7,    null, 'best_before', false, 5),
  ('dairy_chilled',    'Lácteos frescos',                 true,  'fridge',  10,  3,    null, 'use_by',      true,  null),
  ('yogurt_dessert',   'Yogures y postres lácteos',       true,  'fridge',  21,  3,    null, 'best_before', true,  5),
  ('cheese',           'Quesos',                          true,  'fridge',  30,  14,   null, 'best_before', false, 5),
  ('eggs',             'Huevos',                          true,  'fridge',  28,  null, null, 'best_before', false, 7),
  ('milk_uht',         'Leche UHT y bebidas vegetales',   true,  'pantry',  120, 4,    null, 'best_before', false, 14),
  ('fresh_veg',        'Verdura fresca',                  true,  'fridge',  6,   null, null, 'estimate',    false, 3),
  ('fresh_fruit',      'Fruta fresca',                    true,  'fridge',  7,   null, null, 'estimate',    false, 3),
  ('salad_bagged',     'Ensaladas envasadas',             true,  'fridge',  5,   2,    null, 'use_by',      true,  null),
  ('bread_fresh',      'Pan fresco',                      true,  'pantry',  3,   null, null, 'estimate',    false, 2),
  ('bread_packaged',   'Pan de molde y envasado',         true,  'pantry',  10,  null, null, 'best_before', false, 7),
  ('bakery_sweet',     'Bollería y repostería',           true,  'pantry',  5,   null, null, 'best_before', false, 2),
  ('dry_goods',        'Pasta, arroz y legumbres',        true,  'pantry',  365, null, null, 'best_before', false, 90),
  ('canned_jarred',    'Conservas y tarros',              true,  'pantry',  730, 3,    null, 'best_before', false, 180),
  ('oils_condiments',  'Aceites, salsas y condimentos',   true,  'pantry',  365, 90,   null, 'best_before', false, 90),
  ('spices',           'Especias y hierbas secas',        true,  'pantry',  730, null, null, 'best_before', false, 180),
  ('breakfast_snacks', 'Cereales, galletas y snacks',     true,  'pantry',  180, null, null, 'best_before', false, 60),
  ('sweets_chocolate', 'Dulces y chocolate',              true,  'pantry',  270, null, null, 'best_before', false, 60),
  ('frozen',           'Congelados',                      true,  'freezer', 180, null, null, 'best_before', false, 30),
  ('ready_meals',      'Platos preparados',               true,  'fridge',  5,   2,    null, 'use_by',      true,  null),
  ('plant_chilled',    'Tofu y proteínas vegetales',      true,  'fridge',  14,  3,    null, 'use_by',      true,  null),
  ('beverages',        'Bebidas',                         true,  'pantry',  270, null, null, 'best_before', false, 60),
  ('alcohol',          'Vino, cerveza y licores',         true,  'pantry',  730, null, null, 'best_before', false, 365),
  ('coffee_tea',       'Café, té e infusiones',           true,  'pantry',  365, null, null, 'best_before', false, 120),
  ('nuts_dried',       'Frutos secos',                    true,  'pantry',  180, null, null, 'best_before', false, 60),
  ('cleaning',         'Limpieza',                        false, 'pantry',  null, null, null, 'none',       false, null),
  ('toiletries',       'Higiene y cuidado personal',      false, 'pantry',  null, null, null, 'none',       false, null),
  ('household_other',  'Hogar y otros',                   false, 'pantry',  null, null, null, 'none',       false, null),
  ('pet',              'Mascotas',                        false, 'pantry',  null, null, null, 'none',       false, null);

create temp table _ing_raw (l text) on commit drop;
insert into _ing_raw
select l from unnest(string_to_array($data$
chicken_breast|Pechuga de pollo|Chicken breast||0|PECHUGA POLLO;PECH POLLO;PECHUGA DE POLLO FILETES;FILETES PECHUGA;en:chicken-breasts;en:chicken-breast-fillets
chicken_thigh|Muslos de pollo|Chicken thighs||0|MUSLOS POLLO;CONTRAMUSLO POLLO;MUSLO POLLO;en:chicken-thighs
chicken_wings|Alitas de pollo|Chicken wings||0|ALITAS POLLO;ALITAS;en:chicken-wings
whole_chicken|Pollo entero|Whole chicken||0|POLLO ENTERO;POLLO ASADO;POLLO;en:whole-chicken
minced_beef|Carne picada de ternera|Minced beef||0|CARNE PICADA TERNERA;PICADA VACUNO;TERNERA PICADA;PICADA TERNERA;en:minced-beef
minced_pork|Carne picada de cerdo|Minced pork||0|PICADA CERDO;CARNE PICADA CERDO;CARNE PICADA MIXTA;en:minced-pork
beef_steak|Filetes de ternera|Beef steak||0|FILETE TERNERA;FILETES TERNERA;ENTRECOT;CHULETON TERNERA;en:beef-steaks
beef_stew|Ternera para guisar|Stewing beef||0|TERNERA GUISAR;TACOS TERNERA;TERNERA ESTOFAR;en:stewing-beef
pork_loin|Lomo de cerdo|Pork loin||0|LOMO CERDO;LOMO FRESCO;LOMO ADOBADO;en:pork-loin
pork_chops|Chuletas de cerdo|Pork chops||0|CHULETAS CERDO;CHULETA CERDO;CHULETAS;en:pork-chops
pork_ribs|Costillas de cerdo|Pork ribs||0|COSTILLAS CERDO;COSTILLA ADOBADA;COSTILLAS;en:pork-ribs
lamb|Cordero|Lamb||0|CORDERO;PALETILLA CORDERO;PIERNA CORDERO;en:lamb
turkey_breast|Pechuga de pavo|Turkey breast||0|PECHUGA PAVO;FILETES PAVO;PAVO;en:turkey-breast
bacon|Bacon|Bacon||0|BACON;PANCETA;PANCETA AHUMADA;BACON LONCHAS;en:bacon
chorizo|Chorizo|Chorizo||0|CHORIZO SARTA;CHORIZO PICANTE;CHORIZO DULCE;en:chorizo
serrano_ham|Jamón serrano|Serrano ham||0|JAMON SERRANO;JAMON CURADO;TACOS JAMON;JAMON;en:serrano-ham;en:dry-cured-ham
cooked_ham|Jamón cocido|Cooked ham||0|JAMON COCIDO;JAMON YORK;FIAMBRE;en:cooked-ham
fresh_sausage|Salchichas frescas|Fresh sausages||0|SALCHICHAS FRESCAS;SALCHICHA FRESCA;BUTIFARRA;en:fresh-sausages
frankfurt|Salchichas tipo Frankfurt|Frankfurter sausages||0|SALCHICHAS FRANKFURT;FRANKFURT;SALCHICHAS COCIDAS;en:frankfurters
salmon|Salmón|Salmon||0|SALMON FRESCO;LOMOS SALMON;SALMON LOMOS;en:salmon;en:salmon-fillets
hake|Merluza|Hake||0|LOMOS MERLUZA;FILETES MERLUZA;MERLUZA FRESCA;en:hake
cod|Bacalao|Cod||0|BACALAO DESALADO;LOMOS BACALAO;BACALAO SALADO;en:cod;en:salted-cod
sea_bass|Lubina|Sea bass||0|LUBINA FRESCA;LUBINA RACION;en:sea-bass
sea_bream|Dorada|Sea bream||0|DORADA FRESCA;DORADA RACION;en:sea-bream
tuna_fresh|Atún fresco|Fresh tuna||0|ATUN FRESCO;LOMO ATUN;en:tuna-steaks
tuna_canned|Atún en lata|Canned tuna||0|ATUN LATA;ATUN CLARO;ATUN ACEITE;ATUN NATURAL;ATUN;en:canned-tuna;en:tuna
sardines_canned|Sardinas en lata|Canned sardines||0|SARDINAS LATA;SARDINILLAS;SARDINAS;en:canned-sardines
anchovies|Anchoas|Anchovies||0|ANCHOAS;BOQUERONES;BOQUERONES VINAGRE;en:anchovies
prawns|Gambas|Prawns||0|GAMBAS PELADAS;LANGOSTINOS;GAMBON;COLAS GAMBA;en:prawns;en:shrimps
squid|Calamares|Squid||0|CALAMAR;ANILLAS CALAMAR;CHIPIRONES;en:squid
mussels|Mejillones|Mussels||0|MEJILLON;MEJILLONES FRESCOS;en:mussels
smoked_salmon|Salmón ahumado|Smoked salmon||0|SALMON AHUMADO;AHUMADO SALMON;en:smoked-salmon
eggs|Huevos|Eggs|60|0|HUEVOS L;HUEVOS M;HUEVOS CAMPEROS;DOCENA HUEVOS;HUEVOS CLASE L;en:eggs
milk|Leche|Milk||0|LECHE SEMI;LECHE ENTERA;LECHE DESNATADA;LECHE SEMIDESNATADA;LECHE HACENDADO;LECHE UHT;en:milk;en:semi-skimmed-milk
plant_milk|Bebida vegetal|Plant milk||0|BEBIDA AVENA;BEBIDA SOJA;BEBIDA ALMENDRA;LECHE AVENA;LECHE SOJA;en:plant-based-milk;en:oat-milk
cream|Nata|Cream||0|NATA COCINAR;NATA LIQUIDA;NATA MONTAR;en:cream
butter|Mantequilla|Butter||0|MANTEQUILLA SIN SAL;MANTEQUILLA;en:butter
yogurt_plain|Yogur natural|Plain yogurt||0|YOGUR;YOGURES NATURALES;YOGUR NATURAL AZUCARADO;en:plain-yogurts
yogurt_greek|Yogur griego|Greek yogurt||0|GRIEGO NATURAL;YOGUR GRIEGO NATURAL;GRIEGO;en:greek-yogurts
cheese_manchego|Queso manchego|Manchego cheese||0|MANCHEGO CURADO;MANCHEGO TIERNO;QUESO CURADO;en:manchego
cheese_mozzarella|Mozzarella|Mozzarella||0|QUESO MOZZARELLA;MOZARELLA;MOZZARELLA BOLA;en:mozzarella
cheese_parmesan|Parmesano|Parmesan||0|QUESO PARMESANO;GRANA PADANO;PARMIGIANO;PARMESANO RALLADO;en:parmesan
cheese_cream|Queso crema|Cream cheese||0|QUESO UNTAR;PHILADELPHIA;QUESO FRESCO BATIDO;QUESO CREMA UNTABLE;en:cream-cheeses
cheese_feta|Queso feta|Feta||0|FETA;QUESO FETA TROCEADO;en:feta
cheese_grated|Queso rallado|Grated cheese||0|RALLADO 4 QUESOS;QUESO RALLADO PIZZA;QUESO RALLADO EMMENTAL;en:grated-cheeses
cheese_goat|Queso de cabra|Goat cheese||0|QUESO CABRA;ROLLO CABRA;en:goat-cheese
cheese_sliced|Queso en lonchas|Sliced cheese||0|QUESO LONCHAS;LONCHAS QUESO;QUESO FUNDIDO LONCHAS;en:sliced-cheeses
onion|Cebolla|Onion|150|0|CEBOLLAS;CEBOLLA DULCE;CEBOLLA GRANEL;en:onions
red_onion|Cebolla roja|Red onion|150|0|CEBOLLA MORADA;CEBOLLAS ROJAS;en:red-onions
garlic|Ajo|Garlic|5|0|AJOS;CABEZA AJOS;AJO MORADO;en:garlic
tomato|Tomate|Tomato|150|0|TOMATES;TOMATE RAMA;TOMATE ENSALADA;TOMATE PERA;TOMATE CANARIO;en:tomatoes
cherry_tomato|Tomate cherry|Cherry tomatoes||0|TOMATES CHERRY;CHERRY;TOMATE CHERRY PERA;en:cherry-tomatoes
potato|Patata|Potato|200|0|PATATAS;PATATA LAVADA;PATATAS CONSUMO;PATATA GRANEL;en:potatoes
sweet_potato|Boniato|Sweet potato|250|0|BATATA;BONIATOS;en:sweet-potatoes
carrot|Zanahoria|Carrot|80|0|ZANAHORIAS;ZANAHORIA BOLSA;en:carrots
bell_pepper_red|Pimiento rojo|Red bell pepper|180|0|PIMIENTOS ROJOS;PIMIENTO ROJO GRANEL;en:red-bell-peppers
bell_pepper_green|Pimiento verde|Green bell pepper|150|0|PIMIENTOS VERDES;PIMIENTO FREIR;PIMIENTO ITALIANO;en:green-bell-peppers
courgette|Calabacín|Courgette|250|0|CALABACINES;CALABACIN GRANEL;en:zucchini
aubergine|Berenjena|Aubergine|300|0|BERENJENAS;BERENJENA GRANEL;en:eggplants
spinach|Espinacas|Spinach||0|ESPINACA;ESPINACAS FRESCAS;ESPINACA BABY;ESPINACAS BABY;en:spinach
lettuce|Lechuga|Lettuce|300|0|LECHUGA ROMANA;LECHUGA ICEBERG;COGOLLOS;LECHUGA HOJA ROBLE;en:lettuces
mixed_salad|Ensalada mezclada|Mixed salad leaves||0|ENSALADA MEZCLA;ENSALADA LISTA;CANONIGOS;BOLSA ENSALADA;ENSALADA 4 ESTACIONES;en:salads
rocket|Rúcula|Rocket||0|RUCULA;RUCULA BOLSA;en:rocket
cucumber|Pepino|Cucumber|300|0|PEPINOS;PEPINO GRANEL;en:cucumbers
broccoli|Brócoli|Broccoli|300|0|BROCOLI;BROCOLI FRESCO;en:broccoli
cauliflower|Coliflor|Cauliflower|600|0|COLIFLOR FRESCA;en:cauliflower
mushrooms|Champiñones|Mushrooms||0|CHAMPINON;CHAMPINONES;SETAS;CHAMPINON LAMINADO;CHAMPINONES LAMINADOS;en:mushrooms
leek|Puerro|Leek|150|0|PUERROS;PUERRO GRANEL;en:leeks
celery|Apio|Celery||0|APIO;APIO BANDEJA;en:celery
pumpkin|Calabaza|Pumpkin||0|CALABAZA TROCEADA;CALABAZA GRANEL;en:pumpkins
green_beans|Judías verdes|Green beans||0|JUDIAS VERDES;JUDIA VERDE;JUDIA PLANA;JUDIAS PLANAS;en:green-beans
peas|Guisantes|Peas||0|GUISANTES;GUISANTES FRESCOS;GUISANTES DESGRANADOS;en:peas
corn|Maíz|Corn||0|MAIZ;MAZORCA;MAIZ DULCE;MAZORCAS MAIZ;en:sweetcorn
cabbage|Repollo|Cabbage||0|COL;LOMBARDA;COL LOMBARDA;REPOLLO VERDE;en:cabbages
asparagus|Espárragos|Asparagus||0|ESPARRAGOS TRIGUEROS;ESPARRAGOS VERDES;ESPARRAGO;en:asparagus
spring_onion|Cebolleta|Spring onion||0|CEBOLLINO;CEBOLLETAS;en:spring-onions
chard|Acelgas|Chard||0|ACELGA;ACELGAS FRESCAS;en:chard
artichoke|Alcachofas|Artichoke||0|ALCACHOFA;ALCACHOFAS FRESCAS;en:artichokes
avocado|Aguacate|Avocado|200|0|AGUACATES;AGUACATE HASS;AGUACATE MADURO;en:avocados
chilli|Guindilla|Chilli||0|CHILE;GUINDILLAS;CHILE FRESCO;en:chili-peppers
ginger|Jengibre|Ginger||0|JENGIBRE FRESCO;RAIZ JENGIBRE;en:ginger
parsley|Perejil|Parsley||0|PEREJIL FRESCO;PEREJIL MACETA;en:parsley
coriander|Cilantro|Coriander||0|CULANTRO;CILANTRO FRESCO;en:coriander
basil|Albahaca|Basil||0|ALBAHACA FRESCA;ALBAHACA MACETA;en:basil
mint|Menta|Mint||0|HIERBABUENA;MENTA FRESCA;en:mint
rosemary|Romero|Rosemary||0|ROMERO FRESCO;ROMERO MACETA;en:rosemary
beetroot|Remolacha|Beetroot||0|REMOLACHA COCIDA;REMOLACHA;en:beetroots
banana|Plátano|Banana|120|0|PLATANOS;BANANA;PLATANO CANARIAS;BANANAS;en:bananas
apple|Manzana|Apple|180|0|MANZANAS;MANZANA GOLDEN;MANZANA FUJI;MANZANA GALA;en:apples
orange|Naranja|Orange|200|0|NARANJAS;NARANJAS ZUMO;NARANJA MESA;en:oranges
mandarin|Mandarina|Mandarin|80|0|MANDARINAS;CLEMENTINA;CLEMENTINAS;en:mandarins
lemon|Limón|Lemon|100|0|LIMONES;LIMON GRANEL;en:lemons
lime|Lima|Lime|60|0|LIMAS;LIMA GRANEL;en:limes
pear|Pera|Pear|180|0|PERAS;PERA CONFERENCIA;PERA BLANQUILLA;en:pears
strawberry|Fresa|Strawberry||0|FRESAS;FRESON;FRESONES;FRESAS BANDEJA;en:strawberries
grapes|Uvas|Grapes||0|UVA BLANCA;UVA NEGRA;UVAS SIN PEPITAS;en:grapes
peach|Melocotón|Peach|150|0|MELOCOTONES;PARAGUAYO;PARAGUAYOS;MELOCOTON AMARILLO;en:peaches
nectarine|Nectarina|Nectarine|150|0|NECTARINAS;en:nectarines
melon|Melón|Melon||0|MELON PIEL SAPO;MELON GALIA;en:melons
watermelon|Sandía|Watermelon||0|SANDIA;SANDIA ENTERA;SANDIA TROCEADA;en:watermelons
pineapple|Piña|Pineapple||0|PINA;PINA FRESCA;PINA TROCEADA;en:pineapples
kiwi|Kiwi|Kiwi|80|0|KIWIS;KIWI VERDE;en:kiwis
mango|Mango|Mango|300|0|MANGOS;MANGO MADURO;en:mangoes
blueberry|Arándanos|Blueberries||0|ARANDANOS;ARANDANOS BANDEJA;en:blueberries
raspberry|Frambuesas|Raspberries||0|FRAMBUESA;FRAMBUESAS BANDEJA;en:raspberries
plum|Ciruela|Plum|70|0|CIRUELAS;CIRUELA ROJA;en:plums
cherry|Cereza|Cherry||0|CEREZAS;CEREZA PICOTA;PICOTAS;en:cherries
rice|Arroz|Rice||0|ARROZ LARGO;ARROZ REDONDO;ARROZ BOMBA;ARROZ BASMATI;ARROZ INTEGRAL;en:rice
pasta_spaghetti|Espaguetis|Spaghetti||0|ESPAGUETI;SPAGHETTI;ESPAGUETIS N5;en:spaghetti
pasta_penne|Macarrones y penne|Penne and macaroni||0|MACARRONES;PENNE;PLUMAS;FUSILLI;TORNILLOS;PASTA;PASTA SECA;en:pasta
pasta_fresh|Pasta fresca|Fresh pasta||0|PASTA FRESCA;RAVIOLI;TORTELLINI;TAGLIATELLE;en:fresh-pasta
lasagne_sheets|Placas de lasaña|Lasagne sheets||0|LASANA;PLACAS LASANA;LASAGNE;en:lasagne
noodles|Fideos|Noodles||0|FIDEOS FINOS;NOODLES;FIDEOS CHINOS;FIDEUA;en:noodles
couscous|Cuscús|Couscous||0|CUSCUS;CUSCUS INTEGRAL;en:couscous
quinoa|Quinoa|Quinoa||0|QUINOA REAL;QUINOA BLANCA;en:quinoa
oats|Copos de avena|Oats||0|AVENA;COPOS AVENA;AVENA INTEGRAL;en:oats;en:rolled-oats
lentils|Lentejas|Lentils||0|LENTEJA PARDINA;LENTEJAS PARDINAS;LENTEJAS SECAS;en:lentils
chickpeas|Garbanzos|Chickpeas||0|GARBANZO;GARBANZOS SECOS;GARBANZO CASTELLANO;en:chickpeas
white_beans|Alubias blancas|White beans||0|ALUBIAS;JUDIONES;ALUBIA BLANCA;ALUBIAS SECAS;en:white-beans
black_beans|Alubias negras|Black beans||0|FRIJOLES;FRIJOLES NEGROS;ALUBIA NEGRA;en:black-beans
flour|Harina de trigo|Wheat flour||0|HARINA;HARINA TRIGO;HARINA FUERZA;HARINA PANADERA;en:wheat-flours
sugar|Azúcar|Sugar||0|AZUCAR BLANCO;AZUCAR BLANCA;AZUCAR SACO;en:sugars
brown_sugar|Azúcar moreno|Brown sugar||0|AZUCAR MORENO;AZUCAR INTEGRAL;en:brown-sugars
breadcrumbs|Pan rallado|Breadcrumbs||0|PAN RALLADO;REBOZADOR;en:breadcrumbs
bread|Pan|Bread||0|BARRA PAN;PAN BARRA;PAN RUSTICO;BARRA;PAN BLANCO;PAN CANDEAL;en:breads
sliced_bread|Pan de molde|Sliced bread||0|PAN MOLDE;PAN DE MOLDE INTEGRAL;PAN BIMBO;MOLDE BLANCO;en:sliced-breads
tortilla_wraps|Tortillas de trigo|Wraps||0|TORTILLAS TRIGO;WRAPS;TORTILLAS WRAP;TORTITAS TRIGO;en:tortilla-wraps
pizza_dough|Masa de pizza|Pizza dough||0|MASA PIZZA;BASE PIZZA;MASA FRESCA PIZZA;en:pizza-dough
puff_pastry|Hojaldre|Puff pastry||0|MASA HOJALDRE;HOJALDRE LAMINAS;en:puff-pastry
baking_powder|Levadura química|Baking powder||0|LEVADURA;LEVADURA ROYAL;POLVOS HORNEAR;en:baking-powder
cereal|Cereales|Breakfast cereal||0|MUESLI;CORN FLAKES;CEREALES DESAYUNO;CEREALES CHOCO;en:breakfast-cereals
biscuits|Galletas|Biscuits||0|GALLETAS MARIA;GALLETAS DIGESTIVE;GALLETAS INTEGRALES;en:biscuits
tomato_crushed|Tomate triturado|Crushed tomatoes||0|TOMATE NATURAL;TOMATE PELADO;TOMATE TRITURADO LATA;en:crushed-tomatoes;en:canned-tomatoes
tomato_sauce|Tomate frito|Tomato sauce||0|SALSA TOMATE;FRITADA;TOMATE FRITO CASERO;en:tomato-sauces
tomato_paste|Concentrado de tomate|Tomato paste||0|CONCENTRADO TOMATE;TOMATE CONCENTRADO;en:tomato-pastes
canned_chickpeas|Garbanzos cocidos|Cooked chickpeas||0|GARBANZOS COCIDOS;GARBANZOS BOTE;GARBANZOS COCIDOS BOTE;en:cooked-chickpeas
canned_beans|Alubias cocidas|Cooked beans||0|ALUBIAS COCIDAS;ALUBIAS BOTE;ALUBIAS COCIDAS BOTE;en:cooked-beans
canned_lentils|Lentejas cocidas|Cooked lentils||0|LENTEJAS COCIDAS;LENTEJAS BOTE;LENTEJAS COCIDAS BOTE;en:cooked-lentils
canned_corn|Maíz en lata|Canned sweetcorn||0|MAIZ LATA;MAIZ DULCE LATA;MAIZ DULCE BOLSA;en:canned-sweet-corn
olives|Aceitunas|Olives||0|ACEITUNAS VERDES;ACEITUNAS NEGRAS;OLIVAS;ACEITUNAS RELLENAS;en:olives
capers|Alcaparras|Capers||0|ALCAPARRAS;ALCAPARRONES;en:capers
pickles|Pepinillos|Pickles||0|ENCURTIDOS;PEPINILLOS VINAGRE;en:pickles
roasted_peppers|Pimientos asados|Roasted peppers||0|PIMIENTOS ASADOS;PIMIENTO PIQUILLO;PIQUILLOS;en:roasted-peppers
coconut_milk|Leche de coco|Coconut milk||0|LECHE COCO;LECHE DE COCO LATA;en:coconut-milk
jam|Mermelada|Jam||0|CONFITURA;MERMELADA FRESA;MERMELADA MELOCOTON;en:jams
peanut_butter|Crema de cacahuete|Peanut butter||0|CREMA CACAHUETE;MANTEQUILLA CACAHUETE;en:peanut-butter
hummus|Hummus|Hummus||0|HUMUS;HUMMUS CLASICO;en:hummus
pesto|Pesto|Pesto||0|SALSA PESTO;PESTO GENOVES;PESTO ROSSO;en:pesto
olive_oil|Aceite de oliva|Olive oil||1|ACEITE OLIVA;AOVE;ACEITE OLIVA VIRGEN EXTRA;ACEITE OLIVA SUAVE;en:olive-oils
sunflower_oil|Aceite de girasol|Sunflower oil||0|ACEITE GIRASOL;en:sunflower-oils
vinegar|Vinagre|Vinegar||0|VINAGRE VINO;VINAGRE MODENA;VINAGRE MANZANA;en:vinegars
soy_sauce|Salsa de soja|Soy sauce||0|SALSA SOJA;SOJA SALSA;en:soy-sauces
mustard|Mostaza|Mustard||0|MOSTAZA DIJON;MOSTAZA ANTIGUA;en:mustards
mayonnaise|Mayonesa|Mayonnaise||0|MAYONESA LIGHT;MAYONESA HACENDADO;en:mayonnaises
ketchup|Kétchup|Ketchup||0|KETCHUP;KETCHUP TOMATE;SALSA KETCHUP;en:ketchup
honey|Miel|Honey||0|MIEL MILFLORES;MIEL DE FLORES;MIEL ROMERO;en:honeys
stock|Caldo|Stock||0|CALDO POLLO;CALDO VERDURAS;PASTILLAS CALDO;AVECREM;CALDO CARNE;CALDO PESCADO;en:chicken-broths;en:broths
salt|Sal|Salt||1|SAL FINA;SAL GRUESA;SAL MARINA;en:salts
pepper|Pimienta|Pepper||1|PIMIENTA NEGRA;PIMIENTA MOLIDA;PIMIENTA GRANO;en:black-peppers
paprika|Pimentón dulce|Paprika||0|PIMENTON;PIMENTON DULCE;en:paprikas
smoked_paprika|Pimentón ahumado|Smoked paprika||0|PIMENTON AHUMADO;PIMENTON PICANTE;PIMENTON VERA;en:smoked-paprika
cumin|Comino|Cumin||0|COMINO MOLIDO;COMINO GRANO;en:cumins
oregano|Orégano|Oregano||0|OREGANO SECO;OREGANO MOLIDO;en:oreganos
thyme|Tomillo|Thyme||0|TOMILLO SECO;en:thymes
bay_leaf|Laurel|Bay leaf||0|HOJAS LAUREL;LAUREL HOJAS;en:bay-leaves
cinnamon|Canela|Cinnamon||0|CANELA MOLIDA;CANELA RAMA;en:cinnamons
saffron|Azafrán|Saffron||0|COLORANTE;COLORANTE ALIMENTARIO;AZAFRAN HEBRAS;en:saffron
turmeric|Cúrcuma|Turmeric||0|CURCUMA MOLIDA;en:turmeric
curry|Curry|Curry powder||0|CURRY POLVO;CURRY EN POLVO;en:curry-powders
nutmeg|Nuez moscada|Nutmeg||0|NUEZ MOSCADA MOLIDA;en:nutmegs
chilli_flakes|Chile en copos|Chilli flakes||0|CHILE COPOS;PIMIENTA CAYENA;CAYENA;en:chili-flakes
vanilla|Vainilla|Vanilla||0|AZUCAR VAINILLADO;AZUCAR VAINILLA;ESENCIA VAINILLA;en:vanillas
almonds|Almendras|Almonds||0|ALMENDRA;ALMENDRA MARCONA;ALMENDRAS CRUDAS;ALMENDRAS FRITAS;en:almonds
walnuts|Nueces|Walnuts||0|NUECES PELADAS;NUEZ;en:walnuts
peanuts|Cacahuetes|Peanuts||0|CACAHUETE;CACAHUETES FRITOS;CACAHUETES SALADOS;en:peanuts
pine_nuts|Piñones|Pine nuts||0|PINONES;PINONES PELADOS;en:pine-nuts
sesame|Sésamo|Sesame||0|SESAMO;SEMILLAS SESAMO;en:sesame-seeds
raisins|Pasas|Raisins||0|UVAS PASAS;PASAS SULTANAS;en:raisins
mixed_nuts|Frutos secos variados|Mixed nuts||0|FRUTOS SECOS;MEZCLA FRUTOS SECOS;COCKTAIL FRUTOS SECOS;en:mixed-nuts
dark_chocolate|Chocolate negro|Dark chocolate||0|CHOCOLATE NEGRO;CHOCOLATE 70;CHOCOLATE;CHOCOLATE NEGRO 85;en:dark-chocolates
cocoa_powder|Cacao en polvo|Cocoa powder||0|CACAO POLVO;COLACAO;CACAO;NESQUIK;CACAO SOLUBLE;en:cocoa-powders
coffee|Café|Coffee||0|CAFE MOLIDO;CAFE CAPSULAS;CAFE GRANO;CAFE SOLUBLE;CAFE;en:coffees
tea|Té e infusiones|Tea||0|TE NEGRO;TE VERDE;INFUSION;MANZANILLA;INFUSIONES;en:teas
orange_juice|Zumo de naranja|Orange juice||0|ZUMO NARANJA;ZUMO;ZUMO NARANJA EXPRIMIDO;en:orange-juices
water|Agua|Water||1|AGUA MINERAL;AGUA GARRAFA;AGUA BOTELLA;en:waters
sparkling_water|Agua con gas|Sparkling water||0|AGUA GAS;AGUA CON GAS;AGUA MINERAL GAS;en:sparkling-waters
cola|Refresco de cola|Cola||0|COLA;COCA COLA;REFRESCO COLA;COLA ZERO;en:colas
beer|Cerveza|Beer||0|CERVEZA;CERVEZAS;CERVEZA SIN;CERVEZA LATA;en:beers
red_wine|Vino tinto|Red wine||0|TINTO;VINO TINTO RIOJA;VINO TINTO CRIANZA;en:red-wines
white_wine|Vino blanco|White wine||0|BLANCO;VINO BLANCO VERDEJO;VINO BLANCO RUEDA;en:white-wines
frozen_peas|Guisantes congelados|Frozen peas||0|GUISANTES CONGELADOS;GUISANTES BOLSA;en:frozen-peas
frozen_spinach|Espinacas congeladas|Frozen spinach||0|ESPINACAS CONGELADAS;ESPINACAS TROCEADAS;en:frozen-spinach
frozen_veg_mix|Menestra congelada|Frozen mixed vegetables||0|MENESTRA;VERDURAS CONGELADAS;SALTEADO VERDURAS;MENESTRA CONGELADA;en:frozen-vegetables
frozen_fish_fillets|Filetes de pescado congelados|Frozen fish fillets||0|FILETES MERLUZA CONGELADA;PESCADO CONGELADO;PESCADO REBOZADO;en:frozen-fish
frozen_pizza|Pizza congelada|Frozen pizza||0|PIZZA;PIZZA CONGELADA;PIZZA FRESCA;PIZZA JAMON QUESO;en:pizzas
ice_cream|Helado|Ice cream||0|HELADO;TARRINA HELADO;HELADO VAINILLA;en:ice-creams
french_fries|Patatas fritas congeladas|Frozen fries||0|PATATAS FRITAS CONGELADAS;PATATAS BRAVAS CONGELADAS;PATATAS HORNO;en:frozen-french-fries
tofu|Tofu|Tofu||0|TOFU NATURAL;TOFU AHUMADO;TOFU FIRME;en:tofu
potato_crisps|Patatas fritas de bolsa|Crisps||0|PATATAS FRITAS;PATATAS FRITAS BOLSA;SNACK;GANCHITOS;PATATAS CHIPS;en:potato-crisps
croquettes|Croquetas|Croquettes||0|CROQUETAS JAMON;CROQUETAS POLLO;CROQUETAS CASERAS;en:croquettes
gazpacho|Gazpacho|Gazpacho||0|SALMOREJO;GAZPACHO ANDALUZ;en:gazpachos
tortilla_prepared|Tortilla de patata|Spanish omelette||0|TORTILLA PATATA;TORTILLA ESPANOLA;TORTILLA CEBOLLA;en:spanish-omelettes
$data$, E'\n')) as l where l <> '';

insert into public.ingredients (id, name_es, name_en, typical_unit_g, is_basic)
select split_part(l, '|', 1), split_part(l, '|', 2), split_part(l, '|', 3),
       nullif(split_part(l, '|', 4), '')::numeric, split_part(l, '|', 5) = '1'
from _ing_raw;

-- Each ingredient's own Spanish name, then the listed aliases. Off tags keep their lower-case form.
insert into public.ingredient_aliases (alias, kind, ingredient_id)
select public.normalise_alias(split_part(l, '|', 2)), 'name', split_part(l, '|', 1) from _ing_raw
on conflict (alias) do nothing;

insert into public.ingredient_aliases (alias, kind, ingredient_id)
select case when a like 'en:%' then a else public.normalise_alias(a) end,
       case when a like 'en:%' then 'off_tag' else 'name' end,
       split_part(l, '|', 1)
from _ing_raw, lateral unnest(string_to_array(split_part(l, '|', 6), ';')) as a
where a <> ''
on conflict (alias) do nothing;
