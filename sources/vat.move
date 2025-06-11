module gov_vat::vat;

use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};
use sui::package::Publisher;
use sui::sui::SUI;
use sui::coin::Coin;
use sui::balance::{Self, Balance};

const HUNDRED_PERCENT: u64 = 10_000;

const EWrongVATAmount: u64 = 0;
const EPaymentsShouldBeEmpty: u64 = 1;

public struct VATRule has drop {}

public struct VATConfig<phantom T> has store, drop {
    vat_percent: u64,
}

public struct VATOwnerCap has key, store {
    id: UID,
    goods_policy_cap: TransferPolicyCap<Good>,
    services_policy_cap: TransferPolicyCap<Service>,
}

public struct VATExemptionCap has key {
    id: UID
}

public struct VATReceipt has key, store {
    id: UID,
    policy_id: ID,
    bought_item: ID,
    vat_payment_value: u64
}

public struct VATReceiptDuplicata has key, store {
    id: UID,
    original_receipt_id: ID,
    bought_item: ID
}

// We can imagine Good storing a item of type T, such as a NFT.
public struct Good has key, store {
    id: UID
}

// We can imagine Service having more details of which service is provided, such as a category or a company number.
public struct Service has key, store {
    id: UID
}

public fun new_good(
    ctx: &mut TxContext
): Good {
    Good {
        id: object::new(ctx)
    }
}

public fun new_service(
    ctx: &mut TxContext
): Service {
    Service {
        id: object::new(ctx)
    }
}

#[allow(lint(share_owned))]
public(package) fun register_vat_policies(
    publisher: &Publisher,
    ctx: &mut TxContext,
): VATOwnerCap {
    let (mut goods_policy, goods_policy_cap) = transfer_policy::new<Good>(publisher, ctx);
    let (mut services_policy, services_policy_cap) = transfer_policy::new<Service>(publisher, ctx);

    transfer_policy::add_rule(
        VATRule {},
        &mut goods_policy,
        &goods_policy_cap,
        VATConfig<Good> {
            vat_percent: 1_000,
        }
    );

    transfer_policy::add_rule(
        VATRule {},
        &mut services_policy,
        &services_policy_cap,
        VATConfig<Service> {
            vat_percent: 2_000,
        }
    );

    transfer::public_share_object(goods_policy);
    transfer::public_share_object(services_policy);
    
    VATOwnerCap {
        id: object::new(ctx),
        goods_policy_cap,
        services_policy_cap
    }
}

public fun pay_vat<T>(
    policy: &mut TransferPolicy<T>,
    request: &mut TransferRequest<T>,
    payment: Coin<SUI>
) {
    let paid = request.paid();
    let vat_to_pay = get_vat_amount_to_pay(policy, paid);

    assert!(payment.value() == vat_to_pay, EWrongVATAmount);

    transfer_policy::add_to_balance(VATRule {}, policy, payment);
    transfer_policy::add_receipt(VATRule {}, request);
}

public fun pay_vat_b2b<T>(
    policy: &mut TransferPolicy<T>,
    request: &mut TransferRequest<T>,
    receipts: vector<VATReceipt>,
    payments: vector<Coin<SUI>>,
    ctx: &mut TxContext
): Option<VATReceipt> {
    let paid = request.paid();
    let vat_to_pay = get_vat_amount_to_pay(policy, paid);

    let vat_to_rebate = receipts.fold!(0u64, |acc, elem| {
        let VATReceipt { id: receipt_id, vat_payment_value, .. } = elem;

        object::delete(receipt_id);

        acc + vat_payment_value
    });

    transfer_policy::add_receipt(VATRule {}, request);

    if (vat_to_pay > vat_to_rebate) {
        let remaining = vat_to_pay - vat_to_rebate;

        let mut payments_balance: Balance<SUI> = balance::zero();

        payments.do!(|elem| {
            payments_balance.join(elem.into_balance());
        });

        let payments_balance_value = payments_balance.value();

        assert!(payments_balance_value == remaining, EWrongVATAmount);

        transfer_policy::add_to_balance(VATRule {}, policy, payments_balance.into_coin(ctx));

        option::some(
            VATReceipt {
                id: object::new(ctx),
                policy_id: object::id(policy),
                bought_item: request.item(),
                vat_payment_value: remaining,
            }
        )
    } else {
        assert!(payments.is_empty(), EPaymentsShouldBeEmpty);
        payments.destroy_empty();

        let excess = vat_to_rebate - vat_to_pay;

        if (excess == 0) {
            option::none()
        } else {
            option::some(
                VATReceipt {
                    id: object::new(ctx),
                    policy_id: object::id(policy),
                    bought_item: request.item(),
                    vat_payment_value: excess,
                } 
            )
        }
    }
}

public fun split_vat_receipt(
    vat_receipt: &mut VATReceipt,
    amount: u64,
    ctx: &mut TxContext
): VATReceipt {
    assert!(amount > 0, EWrongVATAmount);

    let VATReceipt { policy_id, bought_item, vat_payment_value, .. } = vat_receipt;

    *vat_payment_value = *vat_payment_value - amount;

    VATReceipt {
        id: object::new(ctx),
        policy_id: *policy_id,
        bought_item: *bought_item,
        vat_payment_value: amount
    }
}

public fun get_vat_amount_to_pay<T>(
    policy: &TransferPolicy<T>,
    paid: u64
): u64 {
    let config: &VATConfig<T> = transfer_policy::get_rule(VATRule {}, policy);

    paid * config.vat_percent / HUNDRED_PERCENT
}

public fun confirm_good_purchase(policy: &TransferPolicy<Good>, req: TransferRequest<Good>) {
    transfer_policy::confirm_request(policy, req);
}

public fun withdraw_goods_vat(
    vat_owner_cap: &VATOwnerCap,
    policy: &mut TransferPolicy<Good>,
    receipts: vector<VATReceipt>,
    ctx: &mut TxContext
): Coin<SUI> {
    let withdraw_amount = receipts.fold!(0u64, |acc, receipt| {
        let VATReceipt { id: vat_receipt_id, vat_payment_value, .. } = receipt;

        object::delete(vat_receipt_id);

        acc + vat_payment_value
    });

    policy.withdraw(&vat_owner_cap.goods_policy_cap, option::some(withdraw_amount), ctx)
}

public fun withdraw_services_vat(
    vat_owner_cap: &VATOwnerCap,
    policy: &mut TransferPolicy<Service>,
    receipts: vector<VATReceipt>,
    ctx: &mut TxContext
): Coin<SUI> {
    let withdraw_amount = receipts.fold!(0u64, |acc, receipt| {
        let VATReceipt { id: vat_receipt_id, vat_payment_value, .. } = receipt;

        object::delete(vat_receipt_id);

        acc + vat_payment_value
    });

    policy.withdraw(&vat_owner_cap.services_policy_cap, option::some(withdraw_amount), ctx)
}

public(package) fun generate_vat_receipt_duplicata(
    self: &VATReceipt,
    ctx: &mut TxContext
): VATReceiptDuplicata {
    VATReceiptDuplicata {
        id: object::new(ctx),
        original_receipt_id: object::id(self),
        bought_item: self.bought_item
    }
}

public fun destroy_vat_receipt_duplicata(
    self: VATReceiptDuplicata
) {
    let VATReceiptDuplicata { id, .. } = self;

    object::delete(id);
}