module gov_vat::system;

use sui::kiosk::{KioskOwnerCap};
use sui::package::{Self};
use gov_vat::vat::{Self, VATOwnerCap};
use sui::kiosk::Kiosk;
use gov_vat::vat::Good;
use gov_vat::vat::Service;

public struct SYSTEM has drop {}

public struct GovVATSystem has key {
    id: UID,
    vat_kiosk_id: ID,
    vat_kiosk_owner_cap: KioskOwnerCap,
    vat_owner_cap: VATOwnerCap
}

public struct VATListedItemCap has key, store {
    id: UID,
    item_id: ID
}

public struct GovVATOwnerCap {}

fun init(
    otw: SYSTEM,
    ctx: &mut TxContext
) {
    let publisher = package::claim(otw, ctx);

    let vat_owner_cap = vat::register_vat_policies(
        &publisher,
        ctx,
    );

    let (vat_kiosk, vat_kiosk_owner_cap) = sui::kiosk::new(ctx);

    let gov_vat_system = GovVATSystem {
        id: object::new(ctx),
        vat_kiosk_id: object::id(&vat_kiosk),
        vat_kiosk_owner_cap,
        vat_owner_cap,
    };

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_share_object(vat_kiosk);
    transfer::share_object(gov_vat_system);

}

public fun place_and_list_good(
    vat_kiosk: &mut Kiosk,
    gov_vat_system: &mut GovVATSystem,
    good: Good,
    price: u64,
    ctx: &mut TxContext
): VATListedItemCap {
    place_and_list_in_vat_kiosk(
        vat_kiosk,
        gov_vat_system,
        good,
        price,
        ctx
    )
}

public fun remove_listing<T: key + store>(
    vat_kiosk: &mut Kiosk,
    gov_vat_system: &mut GovVATSystem,
    listed_item_cap: VATListedItemCap
): T {
    let VATListedItemCap { id: listed_item_cap_id, item_id } = listed_item_cap;

    vat_kiosk.delist<T>(
        &gov_vat_system.vat_kiosk_owner_cap,
        item_id
    );

    let item = vat_kiosk.take<T>(
        &gov_vat_system.vat_kiosk_owner_cap,
        item_id
    );

    object::delete(listed_item_cap_id);

    item
}

public fun place_and_list_service(
    vat_kiosk: &mut Kiosk,
    gov_vat_system: &mut GovVATSystem,
    service: Service,
    price: u64,
    ctx: &mut TxContext
): VATListedItemCap {
    place_and_list_in_vat_kiosk(
        vat_kiosk,
        gov_vat_system,
        service,
        price,
        ctx
    )
}

public fun borrow_mut_vat_owner_cap(
    _: &GovVATOwnerCap,
    gov_vat_system: &mut GovVATSystem,
): &mut VATOwnerCap {
    &mut gov_vat_system.vat_owner_cap
}

fun place_and_list_in_vat_kiosk<T: key + store>(
    vat_kiosk: &mut Kiosk,
    gov_vat_system: &GovVATSystem,
    item: T,
    price: u64,
    ctx: &mut TxContext
): VATListedItemCap {
    let item_id = object::id(&item);

    vat_kiosk
        .place_and_list(
            &gov_vat_system.vat_kiosk_owner_cap,
            item,
            price
        );

    VATListedItemCap {
        id: object::new(ctx),
        item_id
    }
}