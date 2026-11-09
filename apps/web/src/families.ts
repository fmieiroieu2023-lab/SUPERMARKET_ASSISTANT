// How the pantry is grouped on screen (design decision D13). Pure presentation: no business rule here.
// Category ids come from the `categories` table; anything unknown lands in "Other".
export const FAMILY_ORDER = [
  "Ready meals & leftovers", "Meat & fish", "Fruit & veg", "Bread & bakery", "Dairy & eggs",
  "Dry goods & tins", "Frozen", "Drinks", "Household", "Other",
] as const;
export type Family = (typeof FAMILY_ORDER)[number];

const MAP: Record<string, Family> = {
  fresh_meat: "Meat & fish", fresh_poultry: "Meat & fish", fresh_fish: "Meat & fish", cured_meat: "Meat & fish",
  fresh_fruit: "Fruit & veg", fresh_veg: "Fruit & veg", salad_bagged: "Fruit & veg",
  bread_fresh: "Bread & bakery", bread_packaged: "Bread & bakery", bakery_sweet: "Bread & bakery",
  dairy_chilled: "Dairy & eggs", yogurt_dessert: "Dairy & eggs", cheese: "Dairy & eggs", eggs: "Dairy & eggs", plant_chilled: "Dairy & eggs",
  dry_goods: "Dry goods & tins", canned_jarred: "Dry goods & tins", oils_condiments: "Dry goods & tins", spices: "Dry goods & tins",
  nuts_dried: "Dry goods & tins", breakfast_snacks: "Dry goods & tins", sweets_chocolate: "Dry goods & tins", coffee_tea: "Dry goods & tins",
  ready_meals: "Ready meals & leftovers",
  frozen: "Frozen",
  beverages: "Drinks", alcohol: "Drinks", milk_uht: "Drinks",
  cleaning: "Household", toiletries: "Household", household_other: "Household", pet: "Household",
};
export const familyOf = (categoryId: string): Family => MAP[categoryId] ?? "Other";

// Illustrated tile per family until each ingredient has its own picture.
export const FAMILY_ICON: Record<Family, { id: string; tile: string }> = {
  "Ready meals & leftovers": { id: "pasta", tile: "#F3D9C9" },
  "Meat & fish": { id: "chicken", tile: "#F2D3B3" },
  "Fruit & veg": { id: "spinach", tile: "#CBE4C7" },
  "Bread & bakery": { id: "bread", tile: "#EDD7B3" },
  "Dairy & eggs": { id: "milk", tile: "#CFDDEE" },
  "Dry goods & tins": { id: "pasta", tile: "#F1E2A4" },
  Frozen: { id: "tuna", tile: "#CFDBE8" },
  Drinks: { id: "oil", tile: "#DCE3AE" },
  Household: { id: "soap", tile: "#BDE8E1" },
  Other: { id: "pasta", tile: "#E3D3BE" },
};
