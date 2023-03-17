import { Test } from "forge-std/Test.sol";
import { Pool } from "../src/Pool.sol";
import { Factory } from "../src/Factory.sol";
import { PoolUnitTest } from "./Pool.unit.test.sol";
import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

import { console2 } from "forge-std/console2.sol";

contract Wallet {
    receive() external payable {}
}

contract Randomizer is Test {
    Factory internal immutable factory;
    Pool internal immutable swapper;

    ERC20PresetMinterPauser internal immutable token0;
    ERC20PresetMinterPauser internal immutable token1;

    address internal immutable maker1;
    address internal immutable taker1;
    address internal immutable maker2;
    address internal immutable taker2;
    address internal immutable makerRecipient;
    address internal immutable takerRecipient;

    uint256 internal constant priceResolution = 1e18;
    uint16 internal immutable tick;

    uint256 internal immutable maximumPrice;
    uint256 internal immutable maximumAmount;

    uint256[] internal makerIndexes;

    struct OrderData {
        uint256 staked;
        uint256 previous;
        uint256 next;
    }

    constructor(uint16 _tick) {
        token0 = new ERC20PresetMinterPauser("token0", "TKN0");
        token1 = new ERC20PresetMinterPauser("token1", "TKN1");
        factory = new Factory();
        tick = _tick;
        swapper = Pool(factory.createPool(address(token0), address(token1), tick));
        maker1 = address(new Wallet());
        taker1 = address(new Wallet());
        maker2 = address(new Wallet());
        taker2 = address(new Wallet());
        makerRecipient = address(new Wallet());
        takerRecipient = address(new Wallet());
        maximumPrice = type(uint256).max / (10000 + tick);
        maximumAmount = type(uint256).max / priceResolution;
    }

    function setUp() public {
        vm.deal(maker1, 1 ether);
        vm.deal(taker1, 1 ether);
        vm.deal(maker2, 1 ether);
        vm.deal(taker2, 1 ether);

        vm.prank(maker1);
        token0.approve(address(swapper), type(uint256).max);

        vm.prank(taker1);
        token1.approve(address(swapper), type(uint256).max);

        vm.prank(maker2);
        token0.approve(address(swapper), type(uint256).max);

        vm.prank(taker2);
        token1.approve(address(swapper), type(uint256).max);
    }

    function _createOrder(uint256 amount, uint256 price, uint256 stake, uint256 seed) internal returns (uint256) {
        // Creates a *valid* order, does not revert by itself
        // The creator of the order is random
        // Returns the index of the order
        price = price % maximumPrice;
        amount = amount % maximumAmount;
        if (amount == 0) amount++;
        if (price == 0) price++;
        // total ethers balance cannot exceed 2^256 or it would give EVM overflow
        if (address(swapper).balance > 0) stake = stake % (type(uint256).max - address(swapper).balance + 1);

        // Now the inputs are fixed, so we control the state change
        // These are priceLevels, orders, id (native), balanceOf (ERC20 of swapper and sender), balance (ethers)
        // BalanceOf and Id checks, which are trivial, are not made in this test because they cause a stack too deep

        // PriceLevels before the order opening (up to 8 allowed)
        uint256[8] memory priceLevels;
        uint256 priceLevel = swapper.priceLevels(0);
        for (uint256 i = 0; i < 8 && priceLevel != 0; i++) {
            priceLevels[i] = priceLevel;
            priceLevel = swapper.priceLevels(priceLevel);
        }
        // Orders before the order opening (up to 8 allowed)
        OrderData[8] memory indexChain;
        (, , , uint256 staked, uint256 previous, uint256 next) = swapper.orders(price, 0);
        for (uint256 i = 0; i < 8 && next != 0; i++) {
            indexChain[i] = OrderData(staked, previous, next);
            (, , , staked, previous, next) = swapper.orders(price, next);
        }

        if (seed % 2 == 1) {
            if (stake > 0) {
                vm.deal(maker1, stake);
            }
            token0.mint(maker1, amount);
            vm.prank(maker1);
            swapper.createOrder{ value: stake }(amount, price, makerRecipient);
        } else {
            if (stake > 0) {
                vm.deal(maker2, stake);
            }
            token0.mint(maker2, amount);
            vm.prank(maker2);
            swapper.createOrder{ value: stake }(amount, price, makerRecipient);
        }
        uint256 madeIndex = swapper.id(price);
        makerIndexes.push(madeIndex);

        // ORDERS CHECKS
        // define new indexChain array for convenience
        OrderData[8] memory newIndexChain;
        (, , , staked, previous, next) = swapper.orders(price, 0);
        for (uint256 i = 0; i < 8 && next != 0; i++) {
            newIndexChain[i] = OrderData(staked, previous, next);
            (, , , staked, previous, next) = swapper.orders(price, next);
        }

        // PRICE LEVEL CHECKS
        // define new price levels array for convenience
        uint256[8] memory newPriceLevels;
        priceLevel = swapper.priceLevels(0);
        for (uint256 i = 0; i < 8 && priceLevel != 0; i++) {
            newPriceLevels[i] = priceLevel;
            priceLevel = swapper.priceLevels(priceLevel);
        }
        uint256 step = 2;
        for (uint256 i = 0; i < 7; i++) {
            if (priceLevels[i] == 0) break;
            // If price is already present, price levels are untouched
            if (price == priceLevels[i]) step = 0; // In this way the step will never be 1
            // Price levels array is shifted precisely in that position and new price is inserted
            if (price > priceLevels[i] && step == 2) {
                step = 1;
                assertEq(price, newPriceLevels[i]);
            }
            assertEq(priceLevels[i], newPriceLevels[i + (step % 2)]);
        }

        return swapper.id(price);
    }

    function _cancelOrder(uint256 index, uint256 price) internal {
        // Cancels an order only if it exists
        // If the order exists, it pranks the order offerer and cancels
        if (makerIndexes.length == 0) return; // (There is no index initialized yet so nothing to do)
        index = makerIndexes[index % makerIndexes.length]; // (Could be empty if it was fulfilled)
        (address offerer, , , , , ) = swapper.orders(price, index);
        if (offerer != address(0)) {
            vm.prank(offerer);
            swapper.cancelOrder(index, price);
        }
    }

    function _fulfillOrder(uint256 amount, uint256 seed)
        internal
        returns (uint256 accountingPaid, uint256 underlyingReceived)
    {
        (uint256 previewAccounting, ) = swapper.previewTake(amount);
        if (seed % 2 == 1) {
            token1.mint(taker1, previewAccounting);
            vm.prank(taker1);
            (accountingPaid, underlyingReceived) = swapper.fulfillOrder(amount, takerRecipient);
        } else {
            token1.mint(taker2, previewAccounting);
            vm.prank(taker2);
            (accountingPaid, underlyingReceived) = swapper.fulfillOrder(amount, takerRecipient);
        }
    }

    function _randomCall(uint256 amount, uint256 price, uint256 stake, uint256 index, uint256 seed)
        internal
        returns (uint256 createdIndex, uint256 accountingPaid, uint256 underlyingReceived)
    {
        if (seed % 3 == 0) createdIndex = _createOrder(amount, price, stake, seed);
        if (seed % 3 == 1) _cancelOrder(index, price);
        if (seed % 3 == 2) (accountingPaid, underlyingReceived) = _fulfillOrder(amount, seed);
    }

    function _modifyAmount(uint256 amount, uint256 seed) internal returns (uint256) {
        // A fairly crazy random number generator based on keccak256 and large primes
        uint256[8] memory bigPrimes;
        bigPrimes[0] = 2; // 2
        bigPrimes[1] = 3; // prime between 2^1 and 2^2
        bigPrimes[2] = 13; // prime between 2^2 and 2^4
        bigPrimes[3] = 251; // prime between 2^4 and 2^8
        bigPrimes[4] = 34591; // prime between 2^8 and 2^16
        bigPrimes[5] = 3883440697; // prime between 2^16 and 2^32
        bigPrimes[6] = 14585268654322704883; // prime between 2^32 and 2^64
        bigPrimes[7] = 5727913735782256336127425223006579443; // prime between 2^64 and 2^128
        // Since 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 = 255 < 256 (or by direct calculation)
        // we can multiply all the bigPrimes without overflow
        // changing the primes (with the same constraints) would bring to an entirely different generator

        uint256 modifiedAmount = amount;
        for (uint256 i = 0; i < 8; i++) {
            uint256 multiplier = uint(keccak256(abi.encodePacked(modifiedAmount % bigPrimes[i], seed))) % bigPrimes[i];
            // Multiplier is fairly random but its logarithm is most likely near to 2^(2^i)
            // A total multiplication will therefore be near 2^255
            // To avoid this, we multiply with a probability of 50% at each round
            // We also need to avoid multiplying by zero, thus we add 1 at each factor
            if (multiplier % 2 != 0)
                modifiedAmount = (1 + (modifiedAmount % bigPrimes[i])) * (1 + (multiplier % bigPrimes[i]));
            // This number could be zero and can overflow, so we increment by one and take modulus at *every* iteration
            modifiedAmount = 1 + (modifiedAmount % bigPrimes[i]);
        }
        return modifiedAmount;
    }
}

contract PoolIntegrationTest is Randomizer {
    constructor() Randomizer(1) {}

    function testRandom(uint256 amount, uint256 price, uint256 stake, uint256 index, uint256 seed)
        public
        returns (uint256 createdIndex, uint256 accountingPaid, uint256 underlyingReceived)
    {
        for (uint256 i = 0; i < 3; i++) {
            (createdIndex, accountingPaid, underlyingReceived) = _randomCall(amount, price, stake, index, seed);
            // Change seeds every time so that even equality of inputs is shuffled
            amount = _modifyAmount(amount, seed);
            price = _modifyAmount(price, (seed / 2) + 1);
            stake = _modifyAmount(stake, (seed / 3) + 2);
            seed = _modifyAmount(seed, (seed / 4) + 3);
        }
    }
}
