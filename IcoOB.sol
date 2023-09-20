// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
interface IPrice {
    function getCurrentPrice() external view returns (uint256);
    function calculatePrice() external view returns (uint256);
    function updatePrice(bool isBuy, uint256 amount) external returns (bool);
}
contract IcoFairOrderBook is AccessControl, ReentrancyGuard {
    using SafeMath for uint256; 
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    enum OrderStatus {Processing, Open, Executed, Error}
    struct Order {
        address trader;
        uint256 amount;
        OrderStatus status;
        address affiliate;
    }
    address private _owner;
    address private _treasury;
    address private _operations; 
    IERC20 public _token;
    IERC20 public _pairToken;
    IPrice private _priceContract;
    uint256 public _tradeFeeAmount;
    uint256 public _affiliateFee;
    uint256 private _currentPrice;
    uint256 public _reserveAmount;
    uint256 public _treasuryAmount;
    uint256 private nextOrderId;
    mapping(uint256 => Order) public buyOrders;
    mapping(uint256 => Order) public sellOrders;
    uint256[] public buyOrderIds = new uint256[](0);
    uint256[] public sellOrderIds = new uint256[](0);
    uint256 constant SCALING_FACTOR = 1e18;
    address constant NO_ADDRESS = 0x0000000000000000000000000000000000000000;
    uint256 constant TREASURE_ID = 2**256 - 1;
    uint256 constant FEE_DENOMINATOR = 10000; 
    uint256 constant ZERO = 100000000; 
    mapping(address => bool) private affiliates;

    constructor() {
        address token = 0xe4556342C37c9c0AA082c66C832505A10B1623D6;
        address pairToken = 0x0000000000000000000000000000000000001010;
        address priceContract = 0xB2aD8Bc1a7043c623b739b0D6C44b396fe95c414;
        _setupRole(DEFAULT_ADMIN_ROLE, 0x4bCE61390fE6e93b46D301BE98F30046e1862350);
        _setupRole(ADMIN_ROLE, 0x4bCE61390fE6e93b46D301BE98F30046e1862350);
        _owner = 0x4bCE61390fE6e93b46D301BE98F30046e1862350;
        _token = IERC20(token);
        _pairToken = IERC20(pairToken);
        _priceContract = IPrice(priceContract);
        _reserveAmount = 0;
        _treasuryAmount = 0;
        _tradeFeeAmount = 25;
        _affiliateFee = 1000;
        _treasury = 0xEDd9187768bE1149e82a99edC43fed9d3F440Ff0;
        _operations = 0xDfA153D5A0a9f0D0436Dbd7BC4436f8703A87c74;
        affiliates[0xDfA153D5A0a9f0D0436Dbd7BC4436f8703A87c74] = true;
    }
    receive() external payable {}
    fallback() external payable {}
    function setOwner(address owner) external onlyRole(ADMIN_ROLE) {
         _owner = owner;
    }
    function setTreasury(address treasury) external onlyRole(ADMIN_ROLE) {
         _treasury = treasury;
    }
    function setOperations(address operations) external onlyRole(ADMIN_ROLE) {
         _operations = operations;
    }
    function addAdmin(address admin) external onlyRole(ADMIN_ROLE) {
        grantRole(ADMIN_ROLE, admin);
    }
    function removeAdmin(address admin) external onlyRole(ADMIN_ROLE) {
        revokeRole(ADMIN_ROLE, admin);
    }
    function addTokenAddress(address token) external onlyRole(ADMIN_ROLE) {
         _token = IERC20(token);
    }
    function addPairTokenAddress(address pairToken) external onlyRole(ADMIN_ROLE) {
         _pairToken = IERC20(pairToken);
    }
    function setTradeFeeAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        _tradeFeeAmount = amount;
    }
    function withdrawTokens(uint256 amount, address to) external onlyRole(ADMIN_ROLE) {
        require(_token.balanceOf(address(this)) >= amount, ">T bal");
        _token.transfer(to, amount);
    }
    function withdrawPairTokens(uint256 amount, address to) external onlyRole(ADMIN_ROLE) {
        require(_pairToken.balanceOf(address(this)) >= amount, ">PT bal");
        _pairToken.transfer(to, amount);
    }
    function addAffiliate(address affiliate) external onlyRole(ADMIN_ROLE) {
        affiliates[affiliate] = true;
    }
    function removeAffiliate(address affiliate) external onlyRole(ADMIN_ROLE) {
        affiliates[affiliate] = false;
    }
    function updateAffiliateFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        require(newFee <= 10000, "Er <=10000");  // assuming basis points
        _affiliateFee = newFee;
    }
    function isAffiliate(address affiliate) internal view returns (bool) {
        return affiliates[affiliate];
    }
    function getBuyOrdersCount() public view returns (uint256) {
        return buyOrderIds.length;
    }
    function getSellOrdersCount() public view returns (uint256) {
        return sellOrderIds.length;
    }
    function updateCurrentPrice() internal returns(uint256) {
        return _currentPrice = _priceContract.getCurrentPrice();
    }
    event OrderPlaced(address indexed user, bool isBuyOrder, uint256 amount, address affiliate);
    function placeOrder(bool isBuyOrder, uint256 amount, address affiliate) external nonReentrant returns (Order memory) {
        require(amount > ZERO, "Amount !> 0");
        Order memory _order = Order({
            trader: msg.sender,
            amount: amount,
            status: OrderStatus.Processing,
            affiliate: affiliate
        });
        return internalizeOrder(_order, isBuyOrder);
    }
    function internalizeOrder(Order memory _order, bool isBuyOrder) internal returns (Order memory) {
        require(updateCurrentPrice() > 0, "inPfail");
        require(updateBalances(), "inBalFail");
        if (isBuyOrder) {
            _order = processBuyOrder(_order);
        } else {
            _order = processSellOrder(_order);
        }
        emit OrderPlaced(_order.trader, isBuyOrder, _order.amount, _order.affiliate);
        uint256 orderId = nextOrderId;
        nextOrderId++;
        updateBalances();
        sanitizeAffiliate(_order);
        if (buyOrderIds.length > 0) {
            matchOrders();
        }
        if (isBuyOrder && buyOrders[orderId].trader != address(0)) {
            return buyOrders[orderId];
        } else if (!isBuyOrder && sellOrders[orderId].trader != address(0)) {
            return sellOrders[orderId];
        } else {
            _order.status = OrderStatus.Executed;
            return _order;
        }
    }
    function sanitizeAffiliate(Order memory _order) internal view returns (Order memory) {
        if (_order.affiliate != NO_ADDRESS && affiliates[_order.affiliate] && _order.affiliate != _order.trader) {
            return _order;
        }
        _order.affiliate = _operations;
        return _order;
    }
    function processBuyOrder(Order memory _order) internal returns (Order memory) {
       uint256 startingPairBalance = _treasuryAmount;
        require(_pairToken.allowance(_order.trader, address(this)) >= _order.amount, "Low PT allow");
        require(_pairToken.balanceOf(_order.trader) >= _order.amount, "Low PT bal");
        require(_pairToken.transferFrom(_order.trader, address(this), _order.amount), "PT tx fail");
        require(_pairToken.balanceOf(address(this)).sub(startingPairBalance) >= _order.amount, "PT tx inac");
        _order.status = OrderStatus.Open;
        buyOrders[nextOrderId] = _order;
        buyOrderIds.push(nextOrderId);
        return _order;
    }
    function processSellOrder(Order memory _order) internal returns (Order memory) {
        uint256 startingTokenBalance = _reserveAmount;
        require(_token.allowance(_order.trader, address(this)) >= _order.amount, "Low T allow");
        require(_token.balanceOf(_order.trader) >= _order.amount, "Low T bal");
        require(_token.transferFrom(_order.trader, address(this), _order.amount), "T tx fail");
        require(_token.balanceOf(address(this)).sub(startingTokenBalance) >= _order.amount, "T tx inac");
        _order.status = OrderStatus.Open;
        sellOrders[nextOrderId] = _order;
        sellOrderIds.push(nextOrderId);
        return _order;
    }
    function matchOrders() internal {
        uint256 i = 0;
        while (i < buyOrderIds.length) { // 2
            uint256 buyOrderId = buyOrderIds[i];
            Order storage buyOrder = buyOrders[buyOrderId];
            if (buyOrder.status != OrderStatus.Open) {
                i++;
                continue;
            }
            uint256 buyOrderTokenAmount = pairsToTokens(buyOrder.amount, _currentPrice);
            if (buyOrderTokenAmount == 0) {
                buyOrder.status = OrderStatus.Error;
                i++;
                continue;
            }
            uint256 j = 0;
            uint256 tradeAmount = 0;
            uint256 pairTradeAmount = 0;
            while (j < sellOrderIds.length && buyOrder.status == OrderStatus.Open) { // 1
                uint256 sellOrderId = sellOrderIds[j];
                Order storage sellOrder = sellOrders[sellOrderId];
                if (sellOrder.status != OrderStatus.Open) {
                    j++;
                    continue;
                }
                tradeAmount = (buyOrderTokenAmount > sellOrder.amount) ? sellOrder.amount : buyOrderTokenAmount;
                pairTradeAmount = 0;
                if (tradeAmount > ZERO && tradeAmount <= _reserveAmount) {
                    pairTradeAmount = executeTrade(false, sellOrderId, sellOrder.trader, buyOrderId, buyOrder.trader, tradeAmount, buyOrder.affiliate); 
                } else if (tradeAmount > _reserveAmount && _reserveAmount > 0) { 
                    tradeAmount = _reserveAmount; 
                    pairTradeAmount = executeTrade(false, sellOrderId, sellOrder.trader, buyOrderId, buyOrder.trader, tradeAmount, buyOrder.affiliate); 
                }
                if(pairTradeAmount > ZERO){
                    if (pairTradeAmount >= buyOrder.amount - ZERO){
                        buyOrder.status = OrderStatus.Executed;
                        _priceContract.updatePrice(true, tradeAmount);
                    }
                    else {
                        buyOrder.amount = buyOrder.amount.sub(pairTradeAmount); 
                    }

                    if (tradeAmount >= sellOrder.amount - ZERO){
                        sellOrder.status = OrderStatus.Executed;
                        _priceContract.updatePrice(false, tradeAmount);
                    }
                    else {
                        sellOrder.amount = sellOrder.amount.sub(tradeAmount); 
                    }
                    updateCurrentPrice();
                    updateBalances(); 
                    buyOrderTokenAmount = pairsToTokens(buyOrder.amount, _currentPrice); 
                }
                if(sellOrder.amount <= ZERO){
                    sellOrder.status = OrderStatus.Executed;
                }
                j++;
            }
            pairTradeAmount = 0;
            tradeAmount = 0;
            if (buyOrderTokenAmount > ZERO && buyOrderTokenAmount <= _reserveAmount) {
                tradeAmount = buyOrderTokenAmount; 
                pairTradeAmount = executeTrade(true, TREASURE_ID, NO_ADDRESS, buyOrderId, buyOrder.trader, tradeAmount, buyOrder.affiliate);
            } else if (buyOrderTokenAmount > _reserveAmount && _reserveAmount > ZERO) {
                tradeAmount = _reserveAmount; 
                pairTradeAmount = executeTrade(true, TREASURE_ID, NO_ADDRESS, buyOrderId, buyOrder.trader, tradeAmount, buyOrder.affiliate);
            }
            if(pairTradeAmount > 0){
                if (pairTradeAmount >= buyOrder.amount){
                    buyOrder.status = OrderStatus.Executed;
                    _priceContract.updatePrice(true, tradeAmount);
                }
                else {
                    buyOrder.amount = buyOrder.amount.sub(pairTradeAmount); 
                }
                updateCurrentPrice();
                updateBalances(); 
                buyOrderTokenAmount = pairsToTokens(buyOrder.amount, _currentPrice); 
            }
            if(buyOrder.amount <= ZERO){
                    buyOrder.status = OrderStatus.Executed;
            } 
            i++;
        }
        removeProcessedOrders(buyOrderIds, buyOrders);
        removeProcessedOrders(sellOrderIds, sellOrders);
    }
    function tokensToPairs(uint256 tokens, uint256 price) public pure returns (uint256 pairs) {
        uint256 pairAmount = tokens.mul(price); 
        pairAmount = pairAmount.div(SCALING_FACTOR);
        return cleanDecimals(pairAmount);
    }
    function pairsToTokens(uint256 pairs, uint256 price) public pure returns (uint256 tokens) {
        uint256 tokenAmount = pairs.mul(SCALING_FACTOR);
        tokenAmount = tokenAmount.div(price);
        return cleanDecimals(tokenAmount);
    }
    function cleanDecimals(uint256 _value) public pure returns (uint256) {
        uint8 decimals = 8;
        uint256 magnitude = 10 ** decimals;
        return (_value / magnitude) * magnitude; 

    }
    function removeProcessedOrders(uint256[] storage orderIds, mapping(uint256 => Order) storage orders) internal returns(bool){
        uint256[] memory newOrderIds = new uint256[](orderIds.length);
        uint256 count = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            if (orders[orderId].status != OrderStatus.Executed) {
                newOrderIds[count] = orderId;
                count++;
            } else {
                delete orders[orderId];
            }
        }
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = newOrderIds[i];
        }
        for (uint256 i = count; i < orderIds.length; i++) {
            orderIds.pop();
        }
        return true;
    }
    function updateBalances() internal returns (bool) {
        _reserveAmount = _token.balanceOf(address(this));
        _treasuryAmount = _pairToken.balanceOf(address(this));
        return true;
    }
    event OrderMatched(uint256 sellOrderId, address seller, uint256 buyOrderId, address buyer, uint256 tokenAmount, uint256 pairTokenAmount, address affiliate); 
    function executeTrade(bool isTreadury, uint256 sellOrderId, address seller, uint256 buyOrderId, address buyer, uint256 tokenAmount, address affiliate) internal returns(uint256) {
        uint256 pairTokenAmount = tokensToPairs(tokenAmount, _currentPrice); 
        emit OrderMatched(sellOrderId, seller, buyOrderId, buyer, tokenAmount, pairTokenAmount, affiliate); 
        if(pairTokenAmount > 0 && pairTokenAmount <= _treasuryAmount && tokenAmount <= _reserveAmount){
            executeTokenTrade(isTreadury, buyer, pairTokenAmount, tokenAmount, affiliate);
            executePairTokennTrade(isTreadury, seller, pairTokenAmount);
            emit OrderMatched(sellOrderId, seller, buyOrderId, buyer, tokenAmount, pairTokenAmount, affiliate);
            return pairTokenAmount;
        }
        return 0;
    }

    function executePairTokennTrade(bool isTreadury, address seller, uint256 pairTokenAmount) internal {
        
        if (isTreadury) {
            uint256 treasury = pairTokenAmount.div(2);
            uint256 operations = pairTokenAmount - treasury;
            unchecked {
                _pairToken.transfer(_treasury, treasury);
                _pairToken.transfer(_operations, operations); 
            }
        }
        else {
            uint256 pfee = pairTokenAmount.mul(_tradeFeeAmount).div(FEE_DENOMINATOR);
            require(_pairToken.transfer(seller, pairTokenAmount.sub(pfee)), "S tx failed");
            _pairToken.transfer(_operations, pfee);
        }
    }

    function executeTokenTrade(bool isTreadury, address buyer, uint256 pairTokenAmount, uint256 tokenAmount, address affiliate) internal returns (uint256) {
        uint256 feeDom = FEE_DENOMINATOR;
        uint256 fee = cleanDecimals(tokenAmount.mul(_tradeFeeAmount).div(feeDom));
        uint256 remaining = tokenAmount.sub(fee);
        require(_token.transfer(buyer, remaining), "B tx failed");
        _token.transfer(_operations, fee); 
        uint256 afee = cleanDecimals(tokenAmount.mul(_affiliateFee).div(feeDom));
        if(isTreadury && _token.balanceOf(address(this)) >= afee){
            unchecked {
                _token.transfer(affiliate, afee);
            }
        }
        return pairTokenAmount;
    }

    error NotOrderOwner(); 
    error OrderAlreadyExecuted();
    event OrderCancelled(address indexed user, uint256 orderId);
    function cancelBuyOrder(uint256 orderId) public nonReentrant {
        if (buyOrders[orderId].trader != msg.sender) {
            revert NotOrderOwner();
        }
        if (buyOrders[orderId].status != OrderStatus.Open) {
            revert OrderAlreadyExecuted(); 
        }
        buyOrders[orderId].status = OrderStatus.Executed;
        unchecked {
            _pairToken.transfer(msg.sender, buyOrders[orderId].amount);
        }
        removeProcessedOrders(buyOrderIds, buyOrders);
        emit OrderCancelled(msg.sender, orderId);
    }

    function cancelSellOrder(uint256 orderId) public nonReentrant {
        if (sellOrders[orderId].trader != msg.sender) {
            revert NotOrderOwner();
        }
        if (sellOrders[orderId].status != OrderStatus.Open) {
            revert OrderAlreadyExecuted();
        }
        sellOrders[orderId].status = OrderStatus.Executed;
        unchecked {
            _token.transfer(msg.sender, sellOrders[orderId].amount);
        }
        removeProcessedOrders(sellOrderIds, sellOrders);
        emit OrderCancelled(msg.sender, orderId); 
    }
}