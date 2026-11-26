#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace pelagic::missionui {

enum class Page {
    Nearby, News, LocalLeads, FollowUps, Journal, Discoveries,
    Charters, Convoys, Combat, Fleet, Intelligence, Campaigns,
    SystemBubble, RegionBubble
};

enum class Input {
    Close, ShowPage, SelectRow, PreviousSheet, NextSheet,
    Track, Route, Primary, Secondary, Scan, CaseFile,
    Interact, Hail, Report, Follow, Mark, Auxiliary
};

struct Action {
    Input kind;
    int value{};
    bool operator==(const Action&) const = default;
};

struct Row {
    std::string title, location, status;
    std::string detail{};
    bool operator==(const Row&) const = default;
};

struct Button {
    Action action;
    std::string title;
    bool enabled=true;
    char shortcut=0; // Optional page-specific key.
    bool operator==(const Button&) const = default;
};

struct Snapshot {
    Page page=Page::Nearby;
    std::string location, title, subtitle, body, message, empty;
    std::vector<Row> rows;
    std::vector<Button> buttons;
    std::size_t selection=0, sheet=0, sheetCount=1;
    bool operator==(const Snapshot&) const = default;
};

} // namespace pelagic::missionui
