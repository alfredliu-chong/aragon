pragma solidity 0.4.18;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/Initializable.sol";
import "@aragon/os/contracts/common/EtherToken.sol";

import "@aragon/os/contracts/lib/zeppelin/token/ERC20.sol";
import "@aragon/os/contracts/lib/zeppelin/math/SafeMath.sol";

import "@aragon/apps-finance/contracts/Finance.sol";

import "./DenominationToken.sol";


/**
 * @title Payroll in multiple currencies
 */
contract Payroll is AragonApp { // , IForwarder { makes coverage crash (removes pure and interface doesnt match)
    using SafeMath for uint;
    using DenominationToken for uint;

    uint256 constant public MAX_UINT = uint256(-1);
    // kernel roles
    bytes32 constant public ADD_EMPLOYEE_ROLE = bytes32(1);
    bytes32 constant public REMOVE_EMPLOYEE_ROLE = bytes32(2);
    bytes32 constant public ALLOWED_TOKENS_MANAGER_ROLE = bytes32(3);
    bytes32 constant public ORACLE_ROLE = bytes32(4);

    struct Employee {
        address accountAddress; // unique, but can be changed over time
        mapping(address => uint256) allocation;
        uint256 denominationTokenSalary; // per second
        uint lastAllocation;
        uint lastPayroll;
        string name;
    }

    uint128 private nextEmployee; // starts at 1
    mapping(uint => Employee) private employees;
    mapping(address => uint) private employeeIds;

    Finance public finance;
    ERC20 public denominationToken;
    EtherToken public etherToken;
    mapping(address => uint256) private exchangeRates;
    mapping(address => bool) private allowedTokens;
    address[] private allowedTokensArray;

    event Fund (address sender, address token, uint amount, uint balance, bytes data);
    event SendPayroll (address employee, address token, uint amount);
    event ExchangeRateSet (address token, uint rate);

    /**
     * @notice Initialize Payroll app for `_finance`. Set ETH and Denomination tokens
     * @param _finance Address of the finance Payroll will rely on (non changeable)
     * @param _etherToken Address of EtherToken
     * @param _denominationToken Address of Denomination Token
     */
    function initialize(
        Finance _finance,
        EtherToken _etherToken,
        ERC20 _denominationToken
    ) external
        onlyInit
    {
        initialized();

        nextEmployee = 1; // leave 0 to check null address mapping
        finance = _finance;
        etherToken = _etherToken;
        denominationToken = _denominationToken;
        exchangeRates[address(denominationToken)] = 1;
    }

    /**
     * @dev Set the Denomination exchange rate for a token. Uses decimals from token
     * @notice Sets the Denomination exchange rate for a token
     * @param token The token address
     * @param denominationExchangeRate The exchange rate
     */
    function setExchangeRate(
        address token,
        uint256 denominationExchangeRate
    )
        external
        authP(ORACLE_ROLE, arr(token, denominationExchangeRate, exchangeRates[token]))
    {
        // Denomination Token is a special one, so we can not allow its exchange rate to be changed
        require(token != address(denominationToken));
        exchangeRates[token] = denominationExchangeRate;
        ExchangeRateSet(token, denominationExchangeRate);
    }

    /**
     * @dev Add token to the allowed set
     * @notice Add token to the allowed set
     * @param _allowedToken New token allowed for payment
     */
    function addAllowedToken(address _allowedToken) external authP(ALLOWED_TOKENS_MANAGER_ROLE, arr(_allowedToken)) {
        require(!allowedTokens[_allowedToken]);
        allowedTokens[_allowedToken] = true;
        allowedTokensArray.push(_allowedToken);
    }

    /*
     * TODO: removeFromAllowedTokens. It wouldn't be trivial, as employees
     * should modifiy their allocation. They should be notified and their
     * last allocation date should be reset.
     */

    /**
     * @dev Add employee to Payroll
     * @notice Add employee to Payroll. See addEmployeeWithNameAndStartDate
     * @param accountAddress Employee's address to receive Payroll
     * @param initialYearlyDenominationSalary Employee's salary
     */
    function addEmployee(
        address accountAddress,
        uint256 initialYearlyDenominationSalary
    )
        external
        authP(ADD_EMPLOYEE_ROLE, arr(initialYearlyDenominationSalary, getTimestamp()))
    {
        _addEmployee(
            accountAddress,
            initialYearlyDenominationSalary,
            "",
            getTimestamp()
        );
    }

    /**
     * @dev Add employee to Payroll
     * @notice Add employee to Payroll. See addEmployeeWithNameAndStartDate
     * @param accountAddress Employee's address to receive Payroll
     * @param initialYearlyDenominationSalary Employee's salary
     * @param name Employee's name
     */
    function addEmployeeWithName(
        address accountAddress,
        uint256 initialYearlyDenominationSalary,
        string name
    )
        external
        authP(ADD_EMPLOYEE_ROLE, arr(initialYearlyDenominationSalary, getTimestamp()))
    {
        _addEmployee(
            accountAddress,
            initialYearlyDenominationSalary,
            name,
            getTimestamp()
        );
    }

    /**
     * @dev Add employee to Payroll
     * @notice Creates employee, adds it to mappings, initializes values.
               Updates also global Payroll salary sum.
     * @param accountAddress Employee's address to receive Payroll
     * @param initialYearlyDenominationSalary Employee's salary
     * @param name Employee's name
     * @param startDate It will actually set initial lastPayroll value
     */
    function addEmployeeWithNameAndStartDate(
        address accountAddress,
        uint256 initialYearlyDenominationSalary,
        string name,
        uint256 startDate
    )
        external
        authP(ADD_EMPLOYEE_ROLE, arr(initialYearlyDenominationSalary, startDate))
    {
        _addEmployee(
            accountAddress,
            initialYearlyDenominationSalary,
            name,
            startDate
        );
    }

    /**
     * @dev Set employee's annual salary
     * @notice Updates also global Payroll salary sum
     * @param employeeId Employee's identifier
     * @param yearlyDenominationSalary Employee's new salary
     */
    function setEmployeeSalary(
        uint256 employeeId,
        uint256 yearlyDenominationSalary
    )
        external
        authP(ADD_EMPLOYEE_ROLE, arr(yearlyDenominationSalary, 0))
    {
        /* check that employee exists */
        require(employeeIds[employees[employeeId].accountAddress] != 0);

        employees[employeeId].denominationTokenSalary = yearlyDenominationSalary.toSecondDenominationToken();
    }

    /**
     * @dev Remove employee from Payroll
     * @notice Updates also global Payroll salary sum
     * @param employeeId Employee's identifier
     */
    function removeEmployee(uint256 employeeId) external auth(REMOVE_EMPLOYEE_ROLE) {
        /* check that employee exists */
        require(employeeIds[employees[employeeId].accountAddress] != 0);

        // Pay owed salary to employee
        // get time that has gone by (seconds)
        uint256 time = getTimestamp().sub(employees[employeeId].lastPayroll);
        if (time > 0)
            _payTokens(employeeId, time);

        delete employeeIds[employees[employeeId].accountAddress];
        delete employees[employeeId];
    }

    /**
     * @dev Sends ETH to Finance. This contract should never receive funds,
     *      but in case it happens, this function allows to recover them.
     * @notice Allows to send ETH from this contract to Finance, to avoid locking them in contract forever.
     */
    /*
    function escapeHatch() external {
        // convert ETH to EtherToken
        etherToken.wrapAndCall.value(this.balance)(address(finance), "Adding Funds");
        assert(this.balance == 0);
        Fund(
            msg.sender,
            address(etherToken),
            msg.value,
            etherToken.balanceOf(this),
            ""
        );
    }
    */

    /**
     * @dev Allows to make a simple payment from this contract to Finance,
            to avoid locked tokens in contract forever.
            This contract should never receive tokens with a simple transfer call,
            but in case it happens, this function allows to recover them.
     * @notice Allows to send tokens from this contract to Finance, to avoid locked tokens in contract forever
     */
    function depositToFinance(address token) external {
        ERC20 tokenContract = ERC20(token);
        uint256 value = tokenContract.balanceOf(this);
        if (value == 0)
            return;

        // make an approvement for the same value to Finance
        tokenContract.approve(address(finance), value);
        // finally deposit those tokens to Finance
        finance.deposit(tokenContract, value, "Adding Funds");
        Fund(
            finance,
            token,
            value,
            tokenContract.balanceOf(this),
            ""
        );
    }

    /**
     * @dev To be able to receive ERC20 Token transfers, using approveAndCall
     *      See, e.g: https://www.ethereum.org/token
     * @notice To be able to receive ERC20 Token transfers, using approveAndCall
     * @param from  Token sender address.
     * @param value Amount of tokens.
     * @param token Token to be received.
     * @param data  Transaction metadata.
     */
    function receiveApproval(
        address from,
        uint256 value,
        address token,
        bytes data
    )
        external
        returns (bool success)
    {
        ERC20 tokenContract = ERC20(token);

        // first send tokens to this contract
        require(tokenContract.transferFrom(from, this, value));
        // then make an aprrovement for the same value to Finance
        tokenContract.approve(address(finance), value);
        // finally deposit those tokens to Finance
        finance.deposit(tokenContract, value, "Adding Funds");

        Fund(
            from,
            token,
            value,
            tokenContract.balanceOf(this),
            data
        );

        return true;
    }

    /**
     * @dev Set token distribution for payments to an employee (the caller)
     * @notice Set token distribution for payments to an employee (the caller).
     *         Only callable once every 6 months
     * @param tokens Array with the tokens to receive, they must belong to allowed tokens for employee
     * @param distribution Array (correlated to tokens) with the proportions (integers over 100)
     */
    function determineAllocation(address[] tokens, uint256[] distribution) external {
        Employee storage employee = employees[employeeIds[msg.sender]];
        // check that employee exists (and matches)
        require(employee.accountAddress == msg.sender);
        // check that enough time has gone by
        require(getTimestamp() > employee.lastAllocation &&
                getTimestamp() - employee.lastAllocation > 15768000); // half a year in seconds

        // check arrays match
        require(tokens.length == distribution.length);

        // check distribution is right
        uint256 sum = 0;
        uint256 i;
        for (i = 0; i < distribution.length; i++) {
            // check token is allowed
            require(allowedTokens[tokens[i]]);
            // set distribution
            employee.allocation[tokens[i]] = distribution[i];
            sum = sum.add(distribution[i]);
        }
        require(sum == 100);

        employee.lastAllocation = getTimestamp();
    }

    /**
     * @dev To withdraw payment by employee (the caller). The amount owed since last call will be transferred.
     * @notice To withdraw payment by employee (the caller). The amount owed since last call will be transferred.
     */
    function payday() external {
        Employee storage employee = employees[employeeIds[msg.sender]];
        // check that employee exists (and matches)
        require(employees[employeeIds[msg.sender]].accountAddress == msg.sender);
        // get time that has gone by (seconds)
        uint256 time = getTimestamp().sub(employees[employeeIds[msg.sender]].lastPayroll);
        require(time > 0);

        bool somethingPaid = _payTokens(employeeIds[msg.sender], time);
        require(somethingPaid);

        // finally update last payroll date
        employee.lastPayroll = getTimestamp();
    }

    /**
     * @dev Change employee account address. To be called by Employee
     * @notice Change employee account address
     * @param newAddress New address to receive payments
     */
    function changeAddressByEmployee(address newAddress) external {
        // check that account doesn't exist
        require(employeeIds[newAddress] == 0);
        // check it's non-null address
        require(newAddress != address(0));
        // check that employee exists (and matches)
        uint256 employeeId = employeeIds[msg.sender];
        Employee storage employee = employees[employeeId];
        // check that employee exists (and matches)
        require(employee.accountAddress == msg.sender);

        employee.accountAddress = newAddress;
        employeeIds[newAddress] = employeeId;
        employeeIds[msg.sender] = 0;
    }

    /**
     * @dev Return all important info too through employees mapping
     * @notice Return all Employee's important info
     * @param employeeId Employee's identifier
     * @return Employee's address to receive payments
     * @return Employee's annual salary
     * @return Employee's name
     * @return Employee's last call to payment distribution date
     * @return Employee's last payment received date
     */
    function getEmployee(uint256 employeeId)
        external
        view
        returns (
            address accountAddress,
            uint256 yearlyDenominationSalary,
            string name,
            uint lastAllocation,
            uint lastPayroll
        )
    {
        Employee storage employee = employees[employeeId];

        accountAddress = employee.accountAddress;
        yearlyDenominationSalary = employee.denominationTokenSalary.toYearlyDenomination();
        name = employee.name;
        lastAllocation = employee.lastAllocation;
        lastPayroll = employee.lastPayroll;
    }

    /**
     * @dev Get payment proportion for a token and an employee (the caller)
     * @notice Get payment proportion for a token and an employee (the caller)
     * @param token The token address
     */
    function getAllocation(address token) external view returns (uint256 allocation) {
        Employee storage employee = employees[employeeIds[msg.sender]];
        // check that employee exists (and matches)
        require(employee.accountAddress == msg.sender);

        allocation = employee.allocation[token];
    }

    /**
     * @dev Get the Denomination exchange rate of a Token
     * @notice Get the Denomination exchange rate of a Token
     * @param token The token address
     * @return denominationExchangeRate The exchange rate
     */
    function getExchangeRate(address token) external view returns (uint256 rate) {
        rate = exchangeRates[token];
    }

    /**
     * @dev Loop over tokens and send Payroll to employee
     * @param employeeId Id of employee receiving payroll
     * @param time Time owed to employee (since last payroll)
     * @return True if something has been paid
     */
    function _payTokens(uint256 employeeId, uint256 time) internal returns (bool somethingPaid) {
        Employee storage employee = employees[employeeId];
        // loop over allowed tokens
        somethingPaid = false;
        for (uint i = 0; i < allowedTokensArray.length; i++) {
            address token = allowedTokensArray[i];
            if (employee.allocation[token] == 0)
                continue;
            require(checkExchangeRate(token));
            // salary converted to token and applied allocation percentage
            uint256 tokenAmount = employee.denominationTokenSalary
                .mul(exchangeRates[token]).mul(employee.allocation[token]) / 100;
            tokenAmount = tokenAmount.mul(time);
            ERC20 tokenContract = ERC20(token);
            finance.newPayment(
                tokenContract,
                employee.accountAddress,
                tokenAmount,
                0,
                0,
                1,
                ""
            );
            SendPayroll(employee.accountAddress, token, tokenAmount);
            somethingPaid = true;
        }
    }

    /**
     * @dev Check that a token has the exchange rate already set
     *      Internal function, needed to ensure that we have the rate before making a payment.
     * @param token The token address
     * @return True if we have the exchange rate, false otherwise
     */
    function checkExchangeRate(address token) internal view returns (bool) {
        if (exchangeRates[token] == 0) {
            return false;
        }
        return true;
    }

    function _addEmployee(
        address accountAddress,
        uint256 initialYearlyDenominationSalary,
        string name,
        uint256 startDate
    )
        internal
    {
        // check that account doesn't exist
        require(employeeIds[accountAddress] == 0);

        uint256 employeeId = nextEmployee;
        employees[employeeId] = Employee({
            accountAddress: accountAddress,
            denominationTokenSalary: initialYearlyDenominationSalary.toSecondDenominationToken(),
            lastAllocation: 0,
            lastPayroll: startDate,
            name: name
        });
        // Ids mapping
        employeeIds[accountAddress] = employeeId;
        // update global variables
        nextEmployee++;
    }

    function getTimestamp() internal view returns (uint256) { return now; }

}
